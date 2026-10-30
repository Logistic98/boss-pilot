import Foundation

@MainActor
final class BossAutomationController: ObservableObject {
    enum AccountOperationOutcome: Equatable {
        case performed
        case busy
        case unavailable
    }

    enum HistorySyncCompletion: Equatable, Sendable {
        case complete
        case partial(failedRouteCount: Int)
    }

    private enum CycleResult: Equatable {
        case performed
        case busy
        case waitingForSession
        case ineligible
    }

    private struct AccountCycleResult: Sendable {
        var accountID: UUID? = nil
        var encounteredBusy = false
        var attemptedInitialSearch = false
    }

    private enum ProfileSynchronizationIntent {
        case regular
        case explicitManualVerificationRecheck

        var allowsManualVerificationChallenge: Bool {
            self == .explicitManualVerificationRecheck
        }
    }

    struct BossHistoryRoute: Sendable {
        let conversationID: String
        let bossID: String
        let securityID: String
        let source: Int
        let groupID: String?
    }

    private enum HistoryReadLane {
        case head
        case gap
        case backfill
    }

    private enum ResumeDispatchStage {
        case preparation
        case attachmentUpload
        case attachmentSave
        case exchangeWrite

        var remoteWriteMayHaveStarted: Bool {
            self == .exchangeWrite
        }

        var isAttachmentWrite: Bool {
            self == .attachmentUpload || self == .attachmentSave
        }
    }

    private enum ResumeExchangePreflight {
        case request(BossResumeRequestPreflight)
        case accept(BossResumeAcceptPreflight)
    }

    private enum ResumeDispatchOutcome: Equatable {
        case noAction
        case completed(status: String)
        case requiresAttention(status: String)
        case authenticationExpired(status: String)
        case cancelled

        var status: String? {
            switch self {
            case .completed(let status),
                 .requiresAttention(let status),
                 .authenticationExpired(let status):
                status
            case .noAction, .cancelled:
                nil
            }
        }

        var abortsMessageSynchronization: Bool {
            switch self {
            case .authenticationExpired, .cancelled:
                true
            case .noAction, .completed, .requiresAttention:
                false
            }
        }
    }

    @Published private(set) var runningAccountIDs: Set<UUID> = []
    @Published private(set) var isWorkerRunning = false
    @Published private(set) var isCycleRunning = false
    @Published private(set) var isManualSyncRunning = false
    @Published private(set) var lastCycleAt: Date?
    @Published private(set) var statusByAccount: [UUID: String] = [:]
    @Published private(set) var lastSearchAtByAccount: [UUID: Date] = [:]
    private var readyResumeBacklogAccountIDs: Set<UUID> = []
    @Published private(set) var lastMessageSyncAtByAccount: [UUID: Date] = [:]

    static let startupWriteDelaySeconds: TimeInterval = 15

    private let api: BossAPIService
    private let resumeExchange: BossResumeExchangeService
    private var workerTask: Task<Void, Never>?
    private var workerGeneration: UInt64 = 0
    private var operationGenerations: [UUID: UInt64] = [:]
    private var operationTokens: [UUID: UInt64] = [:]
    private var resumeExchangeProfileIDs: [UUID: UUID] = [:]
    private var automaticResumeWritePermitAccountIDs: Set<UUID> = []
    private var forceSearchAccountIDs: Set<UUID> = []
    private var detailBacklogAttemptAtByAccount: [UUID: Date] = [:]
    private var automaticWritesAllowedAfter: Date?
    private var terminationRequested = false
    private weak var codexController: CodexController?
    private var backgroundAssessments: [UUID: Task<Void, Never>] = [:]
    private var dailyCommunicationRetryAt: [UUID: Date] = [:]
    private var dailyResumeExchangeRetryAt: [UUID: Date] = [:]
    private var detailReadFailedAt: [String: Date] = [:]

    init(
        api: BossAPIService = .live,
        resumeExchange: BossResumeExchangeService? = nil
    ) {
        self.api = api
        self.resumeExchange = resumeExchange ?? .shared
    }

    deinit {
        workerTask?.cancel()
    }

    func synchronize(using store: AppStore, sessions: BossSessionCoordinator, codex: CodexController) {
        codexController = codex
        if store.snapshot.automation.workerEnabled, store.snapshot.automation.mode == .automatic {
            if !startWorker(using: store, sessions: sessions, codex: codex, persist: false) {
                store.updateAutomation { $0.workerEnabled = false }
            }
        } else {
            stopWorker(using: store, persist: false)
        }
    }

    @discardableResult
    func startWorker(using store: AppStore, sessions: BossSessionCoordinator, codex: CodexController, persist: Bool = true) -> Bool {
        codexController = codex
        guard !terminationRequested else { return false }
        if let cooldownUntil = store.snapshot.automation.safetyCooldownUntil, cooldownUntil > Date() {
            for account in Self.workerConfiguredAccounts(store.snapshot.accounts) {
                statusByAccount[account.id] = "安全冷却中，请在 \(cooldownUntil.formatted(date: .abbreviated, time: .shortened)) 后检查账号并手动启动"
            }
            return false
        }
        guard store.snapshot.automation.mode == .automatic else {
            store.report(BossAutomationError.automaticModeRequired)
            return false
        }
        if store.snapshot.automation.automaticallySearchJobs {
            guard store.snapshot.resume.hasStoredAttachment else {
                store.report(BossAutomationError.resumeRequired)
                return false
            }
        }
        if store.snapshot.automation.automaticallySearchJobs {
            guard store.snapshot.preferences.hasSearchCriteria else {
                store.report(BossAutomationError.searchCriteriaRequired)
                return false
            }
        }
        guard store.snapshot.automation.automaticallySearchJobs || store.snapshot.automation.automaticallyMonitorMessages else {
            store.report(BossAutomationError.noAutomaticTaskEnabled)
            return false
        }
        // 本人验证仅暂停账号任务；保留自动运行意图，等待用户完成复核。
        guard !Self.workerConfiguredAccounts(store.snapshot.accounts).isEmpty else {
            store.report(BossAutomationError.automationCredentialRequired)
            return false
        }
        if persist { store.updateAutomation { $0.workerEnabled = true } }
        guard workerTask == nil else { return true }
        // 每次启动为各账号分配一次即时检索许可，直到该账号检索完成才消耗。
        if store.snapshot.automation.automaticallySearchJobs {
            forceSearchAccountIDs.formUnion(
                Self.workerConfiguredAccounts(store.snapshot.accounts).map(\.id)
            )
        }
        workerGeneration &+= 1
        let generation = workerGeneration
        isWorkerRunning = true
        automaticWritesAllowedAfter = Date().addingTimeInterval(Self.startupWriteDelaySeconds)
        for account in Self.workerConfiguredAccounts(store.snapshot.accounts) {
            statusByAccount[account.id] = "自动运行已启动，正在低频获取首批岗位"
        }
        if persist {
            store.addActivity(
                level: .info,
                title: "自动运行已启动",
                detail: "先读取一组岗位并立即显示首批结果；后续检索、详情、消息和外发统一进入全局慢速通道。"
            )
        }
        workerTask = Task { [weak self, weak store, weak sessions, weak codex] in
            guard let self, let store, let sessions, let codex else { return }
            while !Task.isCancelled,
                  self.workerGeneration == generation,
                  store.snapshot.automation.workerEnabled,
                  store.snapshot.automation.mode == .automatic {
                let cycleResult = await self.runCycleIfAvailable(using: store, sessions: sessions, codex: codex)
                if cycleResult == .busy || cycleResult == .waitingForSession {
                    do {
                        let delay: UInt64 = cycleResult == .busy ? 500_000_000 : 2_000_000_000
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        break
                    }
                    continue
                }
                guard cycleResult == .performed else { break }
                do {
                    try await Task.sleep(
                        nanoseconds: self.nextWorkerDelayNanoseconds(store: store, sessions: sessions)
                    )
                } catch {
                    break
                }
            }
            if self.workerGeneration == generation {
                self.workerTask = nil
                self.isWorkerRunning = false
            }
        }
        return true
    }

    func stopWorker(using store: AppStore, persist: Bool = true) {
        workerGeneration &+= 1
        workerTask?.cancel()
        workerTask = nil
        isWorkerRunning = false
        forceSearchAccountIDs.removeAll()
        readyResumeBacklogAccountIDs.removeAll()
        automaticWritesAllowedAfter = nil
        cancelAllOperations()
        if persist, store.snapshot.automation.workerEnabled {
            store.updateAutomation { $0.workerEnabled = false }
        }
    }

    /// 停止接收新任务，等待在途操作完成；宽限期结束后才释放网络客户端，避免丢失写入结果。
    func prepareForTermination(
        using store: AppStore,
        gracefulTimeoutNanoseconds: UInt64 = 12_000_000_000
    ) async {
        if terminationRequested {
            store.flush()
            return
        }
        terminationRequested = true
        automaticResumeWritePermitAccountIDs.removeAll()

        // 代际检查阻止下一轮任务，在途交换及回读不随 worker 一起取消。
        workerGeneration &+= 1
        let pollNanoseconds: UInt64 = 50_000_000
        var waitedNanoseconds: UInt64 = 0
        while (!runningAccountIDs.isEmpty || isCycleRunning),
              waitedNanoseconds < gracefulTimeoutNanoseconds {
            do {
                try await Task.sleep(nanoseconds: pollNanoseconds)
            } catch {
                break
            }
            waitedNanoseconds = min(
                gracefulTimeoutNanoseconds,
                waitedNanoseconds &+ pollNanoseconds
            )
        }

        let drainedNaturally = runningAccountIDs.isEmpty && !isCycleRunning
        if drainedNaturally {
            let finishingWorker = workerTask
            finishingWorker?.cancel()
            _ = await finishingWorker?.value
        } else {
            // 已提交的交换保留为结果未知；尚未提交的附件准备仍可重试。
            conservativelyFinalizeInterruptedResumeDeliveries(using: store)
            workerTask?.cancel()
            let activeAccountIDs = Array(runningAccountIDs)
            cancelAllOperations()
            for accountID in activeAccountIDs {
                await api.cancelActiveRequests(accountID: accountID)
                codexController?.cancelOperations(accountID: accountID)
            }

            var cancellationWait: UInt64 = 0
            while !runningAccountIDs.isEmpty, cancellationWait < 2_000_000_000 {
                do {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                } catch {
                    break
                }
                cancellationWait &+= pollNanoseconds
            }
            conservativelyFinalizeInterruptedResumeDeliveries(using: store)
        }

        workerTask = nil
        isWorkerRunning = false
        store.flush()
    }

    func runCycle(using store: AppStore, sessions: BossSessionCoordinator, codex: CodexController) async {
        codexController = codex
        guard !terminationRequested else { return }
        _ = await runCycleIfAvailable(using: store, sessions: sessions, codex: codex)
    }

    /// 手动同步只读取 BOSS 数据，不触发开聊或简历发送。
    func synchronizeNow(
        accountID: UUID?,
        using store: AppStore,
        sessions: BossSessionCoordinator,
        codex: CodexController
    ) async {
        codexController = codex
        guard !terminationRequested else { return }
        guard store.snapshot.automation.allowsConnectorReads else {
            store.report(BossAutomationError.connectorReadsDisabled)
            return
        }
        guard !isManualSyncRunning else { return }

        let accounts = store.snapshot.accounts.filter { account in
            account.status == .active && (accountID == nil || account.id == accountID)
        }
        guard !accounts.isEmpty else {
            store.report(BossAutomationError.automationCredentialRequired)
            return
        }

        // 等待共享周期锁时保持手动同步状态，并阻止 worker 抢占下一轮。
        isManualSyncRunning = true
        defer { isManualSyncRunning = false }
        while isCycleRunning, !terminationRequested, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
        guard !terminationRequested, !Task.isCancelled else { return }

        isCycleRunning = true
        automaticResumeWritePermitAccountIDs.removeAll()
        defer {
            automaticResumeWritePermitAccountIDs.removeAll()
            isCycleRunning = false
        }

        var readySessions: [(account: BossAccount, session: BossAccountSessionController)] = []
        for account in accounts {
            if Task.isCancelled { break }
            let session = sessions.session(for: account)
            await session.restoreIfNeeded()
            guard session.phase.isAuthenticated else {
                statusByAccount[account.id] = "等待扫码登录"
                continue
            }
            guard session.automationReady else {
                statusByAccount[account.id] = "接口会话正在准备"
                continue
            }
            guard connectorRequestsAllowed(accountID: account.id, store: store) else {
                continue
            }
            readySessions.append((account, session))
        }

        // 手动刷新复用账号调度：账号内先消息后检索，不同账号可交错等待。
        for (account, session) in readySessions {
            guard !Task.isCancelled else { break }
            await runManualAccountLane(
                account: account,
                session: session,
                store: store,
                codex: codex,
                synchronizeProfileFirst: true
            )
        }
        if !Task.isCancelled { lastCycleAt = Date() }
    }

    private func runManualAccountLane(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        codex: CodexController,
        synchronizeProfileFirst: Bool
    ) async {
        guard !Task.isCancelled else { return }
        if synchronizeProfileFirst {
            let profileOutcome = await waitForAvailableOperation(
                accountID: account.id,
                store: store,
                waitingStatus: "等待当前任务结束后同步账号资料"
            ) {
                await self.synchronizeProfile(account: account, session: session, store: store)
            }
            guard profileOutcome == .performed else { return }
        }

        _ = await waitForAvailableOperation(
            accountID: account.id,
            store: store,
            waitingStatus: "等待当前任务结束后同步最近沟通"
        ) {
            await self.synchronizeMessages(account: account, session: session, store: store)
        }
        guard !Task.isCancelled,
              store.snapshot.accounts.contains(where: { $0.id == account.id }) else { return }
        if store.snapshot.resume.hasStoredAttachment, store.snapshot.preferences.hasSearchCriteria {
            _ = await waitForAvailableOperation(
                accountID: account.id,
                store: store,
                waitingStatus: "等待当前任务结束后同步岗位"
            ) {
                await self.searchJobs(
                    account: account,
                    session: session,
                    store: store,
                    codex: codex,
                    useCodex: true,
                    allowExternalActions: false
                )
            }
        } else {
            statusByAccount[account.id] = "消息已同步；添加附件简历并写下求职要求后可同步岗位"
        }
    }

    private func runCycleIfAvailable(
        using store: AppStore,
        sessions: BossSessionCoordinator,
        codex: CodexController
    ) async -> CycleResult {
        guard !terminationRequested else { return .ineligible }
        guard !isManualSyncRunning else { return .busy }
        let configuredAccounts = Self.workerConfiguredAccounts(store.snapshot.accounts)
        guard store.snapshot.automation.mode == .automatic,
              !configuredAccounts.isEmpty else { return .ineligible }
        guard store.snapshot.automation.automaticallySearchJobs ||
                store.snapshot.automation.automaticallyMonitorMessages else {
            if store.snapshot.automation.workerEnabled {
                store.updateAutomation { $0.workerEnabled = false }
            }
            return .ineligible
        }
        if let cooldownUntil = store.snapshot.automation.safetyCooldownUntil,
           cooldownUntil > Date() {
            let status = "风控安全冷却中，最早于 \(cooldownUntil.formatted(date: .abbreviated, time: .shortened)) 恢复"
            for account in configuredAccounts {
                statusByAccount[account.id] = status
            }
            return .performed
        } else if store.snapshot.automation.safetyCooldownUntil != nil {
            store.updateAutomation { $0.safetyCooldownUntil = nil }
        }
        let activeAccounts = Self.workerScheduleEligibleAccounts(configuredAccounts)
        guard !activeAccounts.isEmpty else {
            for account in configuredAccounts where account.manualVerificationChallenge != nil {
                statusByAccount[account.id] = "等待本人完成 BOSS 验证并重新检查"
            }
            return .waitingForSession
        }
        guard !isCycleRunning else { return .busy }
        isCycleRunning = true
        automaticResumeWritePermitAccountIDs.removeAll()
        defer {
            automaticResumeWritePermitAccountIDs.removeAll()
            isCycleRunning = false
        }
        var readyAccountCount = 0
        var encounteredBusyAccount = false
        var encounteredManualVerification = false
        var encounteredWaitingSession = false
        var readySessions: [(account: BossAccount, session: BossAccountSessionController)] = []
        for account in activeAccounts {
            if Task.isCancelled { break }
            let session = sessions.session(for: account)
            await session.restoreIfNeeded()
            guard session.phase.isAuthenticated else {
                statusByAccount[account.id] = "等待扫码登录"
                encounteredWaitingSession = true
                continue
            }
            guard session.automationReady else {
                statusByAccount[account.id] = "接口会话正在准备"
                encounteredWaitingSession = true
                continue
            }
            guard connectorRequestsAllowed(accountID: account.id, store: store) else {
                encounteredManualVerification = true
                continue
            }
            readyAccountCount += 1
            readySessions.append((account, session))
        }

        if encounteredBusyAccount, readySessions.isEmpty { return .busy }
        guard readyAccountCount > 0 else {
            return encounteredManualVerification && !encounteredWaitingSession
                ? .ineligible
                : .waitingForSession
        }

        if store.snapshot.automation.automaticallyMonitorMessages,
           store.snapshot.automation.automaticallySendResume {
            automaticResumeWritePermitAccountIDs = Set(readySessions.map { $0.account.id })
        }

        // 账号内串行以保护会话和额度，不同账号可交错等待网络结果。
        let accountResults = await withTaskGroup(of: AccountCycleResult.self) { group in
            for (account, session) in readySessions {
                guard !Task.isCancelled else { break }
                let forceInitialSearch = forceSearchAccountIDs.contains(account.id)
                group.addTask { @MainActor in
                    await self.runAutomaticAccountLane(
                        account: account, session: session, store: store, codex: codex,
                        forceInitialSearch: forceInitialSearch
                    )
                }
            }
            var results: [AccountCycleResult] = []
            for await result in group { results.append(result) }
            return results
        }
        for result in accountResults where result.attemptedInitialSearch {
            if let accountID = result.accountID {
                forceSearchAccountIDs.remove(accountID)
            }
        }
        encounteredBusyAccount = encounteredBusyAccount || accountResults.contains { $0.encounteredBusy }
        if encounteredBusyAccount { return .busy }

        lastCycleAt = Date()
        return .performed
    }

    private func runAutomaticAccountLane(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        codex: CodexController,
        forceInitialSearch: Bool
    ) async -> AccountCycleResult {
        var result = AccountCycleResult(accountID: account.id)
        guard !Task.isCancelled,
              store.snapshot.accounts.contains(where: { $0.id == account.id && $0.status == .active }) else {
            return result
        }

        if !session.profileBindingVerified || profileSyncIsDue(accountID: account.id, store: store) {
            let profileOutcome = if forceInitialSearch,
                                    !session.profileBindingVerified,
                                    store.snapshot.accounts.first(where: { $0.id == account.id })?
                                        .remoteProfile?.remoteID.nilIfBlank != nil {
                await verifyPersistedProfileBinding(
                    account: account,
                    session: session,
                    store: store
                )
            } else {
                await synchronizeProfile(account: account, session: session, store: store)
            }
            switch profileOutcome {
            case .performed:
                break
            case .busy:
                statusByAccount[account.id] = "等待该账号的当前任务完成"
                result.encounteredBusy = true
                return result
            case .unavailable:
                return result
            }
        }
        guard session.profileBindingVerified,
              store.snapshot.accounts.contains(where: {
                  $0.id == account.id && $0.remoteProfile?.remoteID.nilIfBlank != nil
              }) else { return result }

        // 启动时优先唤醒已就绪的开聊队列，避免被完整检索和消息同步阻塞。
        if store.snapshot.automation.allowsExternalActions,
           store.snapshot.automation.automaticallySendGreetings,
           store.hasQueuedAutomaticGreetingCandidate(accountID: account.id),
           let automaticWritesAllowedAfter,
           automaticWritesAllowedAfter > Date() {
            statusByAccount[account.id] =
                "已有待开聊岗位，最早于 \(automaticWritesAllowedAfter.formatted(date: .omitted, time: .shortened)) 逐个开聊"
            return result
        }

        // 先评估缓存岗位，使现有候选尽快进入该账号的开聊队列。
        if store.snapshot.automation.automaticallyAssessJobs {
            let assessedCount = await store.assessPendingJobsLocally(accountID: account.id)
            if assessedCount > 0 {
                statusByAccount[account.id] = "已评估 \(assessedCount) 个已有岗位，正在选择合适岗位"
            }
        }

        guard !Task.isCancelled, session.automationReady else { return result }
        var greetingPerformed = false
        if store.snapshot.automation.allowsExternalActions,
           store.snapshot.automation.automaticallySendGreetings {
            let greetingOutcome = await sendNextQualifiedGreeting(
                account: account,
                session: session,
                store: store
            )
            if greetingOutcome == .busy {
                result.encounteredBusy = true
                return result
            }
            if greetingOutcome == .performed {
                greetingPerformed = true
            }
        }

        // 招聘方回复优先于岗位详情读取和 Codex 评估。
        if store.snapshot.automation.automaticallyMonitorMessages,
           !Task.isCancelled,
           messageSyncIsDue(accountID: account.id, store: store),
           await synchronizeMessages(
               account: account,
               session: session,
               store: store,
               allowExternalActions: true
           ) == .busy {
            statusByAccount[account.id] = "等待该账号的当前任务完成"
            result.encounteredBusy = true
            return result
        }

        if !greetingPerformed,
           store.snapshot.automation.automaticallySearchJobs,
           !Task.isCancelled,
           searchIsDue(
               accountID: account.id,
               store: store,
               forceInitialSearch: forceInitialSearch
           ) {
            let detailBacklogOnly = usesCandidateSupply(store: store)
                ? !forceInitialSearch && hasPersistedDetailBacklog(accountID: account.id, store: store)
                : !AutomationWorkerSchedulePolicy.jobSearchIsDue(
                    lastCompletedAt: effectiveLastSearchAt(accountID: account.id, store: store),
                    intervalMinutes: effectiveSearchIntervalMinutes(accountID: account.id, store: store),
                    forceInitialSearch: forceInitialSearch,
                    now: Date()
                )
            let searchOutcome = await searchJobs(
                account: account,
                session: session,
                store: store,
                codex: codex,
                useCodex: true,
                allowExternalActions: false,
                startupQuickPass: forceInitialSearch,
                detailBacklogOnly: detailBacklogOnly,
                prioritizeGreetings: true
            )
            if searchOutcome == .performed {
                result.attemptedInitialSearch = forceInitialSearch
            } else if searchOutcome == .busy {
                statusByAccount[account.id] = "等待该账号的当前任务完成"
                result.encounteredBusy = true
                return result
            }
        }

        // 新候选的额度和间隔按所属账号身份校验。
        if !greetingPerformed,
           store.snapshot.automation.allowsExternalActions,
           store.snapshot.automation.automaticallySendGreetings,
           !Task.isCancelled {
            let greetingOutcome = await sendNextQualifiedGreeting(
                account: account,
                session: session,
                store: store
            )
            if greetingOutcome == .busy {
                result.encounteredBusy = true
                return result
            }
        }

        return result
    }

    @discardableResult
    func searchJobs(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        codex: CodexController,
        useCodex: Bool = true,
        allowExternalActions: Bool = false,
        startupQuickPass: Bool = false,
        detailBacklogOnly: Bool = false,
        prioritizeGreetings: Bool = false
    ) async -> AccountOperationOutcome {
        codexController = codex
        guard store.snapshot.accounts.contains(where: { $0.id == account.id && $0.status == .active }) else { return .unavailable }
        guard connectorRequestsAllowed(accountID: account.id, store: store) else { return .unavailable }
        guard store.snapshot.automation.allowsConnectorReads else {
            store.report(BossAutomationError.connectorReadsDisabled)
            return .unavailable
        }
        guard store.snapshot.resume.hasStoredAttachment else {
            store.report(BossAutomationError.resumeRequired)
            return .unavailable
        }
        guard await ensureProfileBinding(account: account, session: session, store: store) else { return .unavailable }
        guard let identityRevision = session.currentIdentityRevision(requiringProfileBinding: true) else { return .unavailable }
        guard let operationGeneration = beginOperation(accountID: account.id, profileID: account.webProfileID) else { return .busy }
        defer {
            // 从批次完成计时，避免慢请求结束后立即连续补货。
            detailBacklogAttemptAtByAccount[account.id] = Date()
            finishOperation(accountID: account.id, generation: operationGeneration)
        }
        do {
            let requestToken = api.requestToken(accountID: account.id)
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else { return .unavailable }
            var credential = try session.credential()
            guard credential.isAutomationReady else { throw BossAutomationError.incompleteWebCredential }
            let searchTargets = try resolvedJobSearchTargets(store: store)
            guard let searchPlanFingerprint = jobSearchPlanFingerprint(
                accountID: account.id,
                targets: searchTargets,
                store: store
            ) else {
                throw BossAutomationError.automationCredentialRequired
            }
            let searchPage = store.snapshot.automation.nextJobSearchPage(
                accountID: account.id,
                planFingerprint: searchPlanFingerprint
            )
            let activeSearchTargets = detailBacklogOnly ? [] : (startupQuickPass
                ? Array(searchTargets.prefix(1))
                : searchTargets)
            statusByAccount[account.id] = startupQuickPass
                ? "正在获取首批岗位·第 \(searchPage) 页"
                : "正在低频检索 \(activeSearchTargets.count) 组岗位条件·第 \(searchPage) 页"

            var remoteJobs: [BossRemoteJob] = []
            for target in activeSearchTargets {
                let result = try await api.searchJobs(
                    accountID: account.id,
                    profileID: account.webProfileID,
                    credential: credential,
                    requestToken: requestToken,
                    query: target.query,
                    cityCode: target.cityCode,
                    page: searchPage
                )
                guard operationIsCurrent(
                    accountID: account.id,
                    generation: operationGeneration,
                    store: store,
                    session: session,
                    identityRevision: identityRevision
                ) else { return .unavailable }
                credential = result.refreshedCredential
                guard await applyRefreshedCredential(
                    credential,
                    account: account,
                    session: session,
                    store: store,
                    identityRevision: identityRevision
                ) else { return .unavailable }
                let fetchedListings = result.value.filter { $0.remoteJobID.nilIfBlank != nil }
                    .map { $0.listing(accountID: account.id) }
                store.upsertJobs(fetchedListings)
                store.flush()
                remoteJobs.append(contentsOf: result.value)
            }

            var seen = Set<String>()
            remoteJobs = remoteJobs.filter {
                seen.insert($0.stableRemoteKey).inserted
            }
            let unstableJobCount = remoteJobs.filter { $0.remoteJobID.nilIfBlank == nil }.count
            if unstableJobCount > 0 {
                remoteJobs.removeAll { $0.remoteJobID.nilIfBlank == nil }
                store.addActivity(
                    accountID: account.id,
                    level: .warning,
                    title: "已忽略缺少稳定标识的岗位",
                    detail: "BOSS 本次有 \(unstableJobCount) 个岗位缺少可验证的岗位 ID，为避免重复或串岗，没有保存或执行自动操作。"
                )
            }
            if startupQuickPass {
                let firstListings = remoteJobs.map {
                    $0.listing(accountID: account.id, detailFetchedAt: nil)
                }
                statusByAccount[account.id] = "首批已找到 \(firstListings.count) 个岗位，正在补齐详情"
                store.addActivity(
                    accountID: account.id,
                    level: .success,
                    title: "首批岗位已显示",
                    detail: "启动后先完成 1 组检索并保存 \(firstListings.count) 个岗位；完整检索会按低频周期继续。"
                )
            }
            let existingJobsByRemoteID = Dictionary(
                store.snapshot.jobs.compactMap { job -> (String, JobListing)? in
                    guard job.accountID == account.id,
                          let remoteJobID = job.remoteJobID?.nilIfBlank else { return nil }
                    return (remoteJobID, job)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let currentRemoteJobIDs = Set(remoteJobs.compactMap { $0.remoteJobID.nilIfBlank })
            var persistedDetailBacklog = store.snapshot.jobs.filter { job in
                job.accountID == account.id &&
                    job.stage == .discovered &&
                    !job.hasCachedDetail &&
                    job.remoteJobID?.nilIfBlank != nil &&
                    job.securityID?.nilIfBlank != nil &&
                    job.listID?.nilIfBlank != nil &&
                    !currentRemoteJobIDs.contains(job.remoteJobID ?? "") &&
                    !JobMatchingPolicy.hasDefinitiveListMismatch(job: job, preferences: store.snapshot.preferences) &&
                    JobDetailBatchPolicy.canReadDetail(lastFailureAt: detailReadFailedAt[job.id])
            }
            let priorityJobs = remoteJobs.map { $0.listing(accountID: account.id, detailFetchedAt: nil) } + persistedDetailBacklog
            let priorityPreferences = store.snapshot.preferences
            // 在后台为每个岗位解析一次要求，避免在排序比较器中重复计算。
            let priorityTask = Task.detached(priority: .utility) {
                try JobDetailBatchPolicy.priorityScores(jobs: priorityJobs, preferences: priorityPreferences)
            }
            let scores = try await withTaskCancellationHandler {
                try await priorityTask.value
            } onCancel: {
                priorityTask.cancel()
            }
            guard operationIsCurrent(accountID: account.id, generation: operationGeneration,
                                     store: store, session: session, identityRevision: identityRevision) else { return .unavailable }
            remoteJobs.sort { scores[$0.remoteJobID, default: Int.max] < scores[$1.remoteJobID, default: Int.max] }
            persistedDetailBacklog.sort { lhs, rhs in
                let left = scores[lhs.remoteJobID ?? "", default: Int.max]
                let right = scores[rhs.remoteJobID ?? "", default: Int.max]
                if left != right { return left < right }
                if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
                return lhs.id < rhs.id
            }
            let currentDetailReadAllowed = remoteJobs.map {
                let listing = $0.listing(accountID: account.id)
                return !JobMatchingPolicy.hasDefinitiveListMismatch(job: listing, preferences: store.snapshot.preferences) &&
                    JobDetailBatchPolicy.canReadDetail(lastFailureAt: detailReadFailedAt[listing.id])
            }
            let currentPendingDetailCount = remoteJobs.indices.filter {
                existingJobsByRemoteID[remoteJobs[$0].remoteJobID]?.hasCachedDetail != true &&
                    !remoteJobs[$0].securityID.isEmpty && currentDetailReadAllowed[$0]
            }.count
            let allocation = startupQuickPass
                ? JobDetailBatchPolicy.startupAllocation(currentCount: currentPendingDetailCount, persistedCount: persistedDetailBacklog.count)
                : JobDetailBatchPolicy.allocation(
                    currentCount: currentPendingDetailCount,
                    persistedCount: persistedDetailBacklog.count
                )
            let detailIndices = JobDetailBatchPolicy.selectedIndices(
                hasCachedDetail: remoteJobs.map {
                    existingJobsByRemoteID[$0.remoteJobID]?.hasCachedDetail == true
                },
                hasSecurityID: remoteJobs.indices.map { !remoteJobs[$0].securityID.isEmpty && currentDetailReadAllowed[$0] },
                limit: allocation[0]
            )
            let selectedPersistedBacklog = Array(persistedDetailBacklog.prefix(allocation[1]))
            let pendingDetailCount = currentPendingDetailCount + persistedDetailBacklog.count
            let detailLimit = detailIndices.count + selectedPersistedBacklog.count
            var detailReadCount = 0
            var detailFetchedAtByRemoteKey: [String: Date] = [:]
            var hydratedPersistedListings: [JobListing] = []
            if detailLimit > 0 {
                statusByAccount[account.id] = pendingDetailCount > detailLimit
                    ? "补齐缺失详情：本批 \(detailLimit) 个，待补齐 \(pendingDetailCount) 个"
                    : "正在读取 \(detailLimit) 个岗位详情"
            }
            for index in detailIndices {
                if prioritizeGreetings,
                   candidateSupplyIsFull(accountID: account.id, store: store) ||
                    shouldYieldToGreeting(accountID: account.id, store: store) { break }
                do {
                    detailReadCount += 1
                    let detail = try await api.jobDetail(
                        accountID: account.id,
                        profileID: account.webProfileID,
                        credential: credential,
                        requestToken: requestToken,
                        securityID: remoteJobs[index].securityID,
                        listID: remoteJobs[index].listID
                    )
                    guard operationIsCurrent(
                        accountID: account.id,
                        generation: operationGeneration,
                        store: store,
                        session: session,
                        identityRevision: identityRevision
                    ) else { return .unavailable }
                    credential = detail.refreshedCredential
                    guard await applyRefreshedCredential(
                        credential,
                        account: account,
                        session: session,
                        store: store,
                        identityRevision: identityRevision
                    ) else { return .unavailable }
                    remoteJobs[index] = remoteJobs[index].merging(detail.value)
                    remoteJobs[index].description = detail.value.description
                    let fetchedAt = Date()
                    detailFetchedAtByRemoteKey[remoteJobs[index].stableRemoteKey] = fetchedAt
                    store.upsertJobs([remoteJobs[index].listing(accountID: account.id, detailFetchedAt: fetchedAt)])
                    if store.snapshot.automation.automaticallyAssessJobs {
                        _ = await store.assessPendingJobsLocally(accountID: account.id)
                    }
                    store.flush()
                    if remoteJobs[index].description.nilIfBlank != nil {
                        detailReadFailedAt[remoteJobs[index].listing(accountID: account.id).id] = nil
                    } else {
                        detailReadFailedAt[remoteJobs[index].listing(accountID: account.id).id] = Date()
                        store.addActivity(
                            accountID: account.id,
                            level: .warning,
                            title: "岗位详情缺少职位描述",
                            detail: "\(remoteJobs[index].title)：不会推荐、Codex 评估或自动开聊。"
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch BossAPIError.webTokenExpired {
                    throw BossAPIError.webTokenExpired
                } catch BossAPIError.authenticationRequired {
                    throw BossAPIError.authenticationRequired
                } catch let error as BossAPIError {
                    if case .manualVerificationRequired = error {
                        throw error
                    }
                    if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    detailReadFailedAt[remoteJobs[index].listing(accountID: account.id).id] = Date()
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "岗位详情读取失败",
                        detail: "\(remoteJobs[index].title)：\(error.localizedDescription)"
                    )
                } catch {
                    if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    detailReadFailedAt[remoteJobs[index].listing(accountID: account.id).id] = Date()
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "岗位详情读取失败",
                        detail: "\(remoteJobs[index].title)：\(error.localizedDescription)"
                    )
                }
            }
            for persistedJob in selectedPersistedBacklog {
                if prioritizeGreetings,
                   candidateSupplyIsFull(accountID: account.id, store: store) ||
                    shouldYieldToGreeting(accountID: account.id, store: store) { break }
                guard let securityID = persistedJob.securityID?.nilIfBlank,
                      let listID = persistedJob.listID?.nilIfBlank else { continue }
                do {
                    detailReadCount += 1
                    let detail = try await api.jobDetail(
                        accountID: account.id,
                        profileID: account.webProfileID,
                        credential: credential,
                        requestToken: requestToken,
                        securityID: securityID,
                        listID: listID
                    )
                    guard operationIsCurrent(
                        accountID: account.id,
                        generation: operationGeneration,
                        store: store,
                        session: session,
                        identityRevision: identityRevision
                    ) else { return .unavailable }
                    credential = detail.refreshedCredential
                    guard await applyRefreshedCredential(
                        credential,
                        account: account,
                        session: session,
                        store: store,
                        identityRevision: identityRevision
                    ) else { return .unavailable }
                    var hydrated = BossRemoteJob(listing: persistedJob).merging(detail.value)
                    hydrated.description = detail.value.description
                    let listing = hydrated.listing(accountID: account.id, detailFetchedAt: Date())
                    hydratedPersistedListings.append(listing)
                    store.upsertJobs([listing])
                    if store.snapshot.automation.automaticallyAssessJobs {
                        _ = await store.assessPendingJobsLocally(accountID: account.id)
                    }
                    store.flush()
                    detailReadFailedAt[persistedJob.id] = nil
                    if !listing.hasAuthoritativeDescription {
                        store.addActivity(
                            accountID: account.id,
                            level: .warning,
                            title: "岗位详情缺少职位描述",
                            detail: "\(persistedJob.title)：不会推荐、Codex 评估或自动开聊。"
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch BossAPIError.webTokenExpired {
                    throw BossAPIError.webTokenExpired
                } catch BossAPIError.authenticationRequired {
                    throw BossAPIError.authenticationRequired
                } catch let error as BossAPIError {
                    if case .manualVerificationRequired = error { throw error }
                    if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    detailReadFailedAt[persistedJob.id] = Date()
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "岗位详情读取失败",
                        detail: "\(persistedJob.title)：\(error.localizedDescription)"
                    )
                } catch {
                    if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    detailReadFailedAt[persistedJob.id] = Date()
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "岗位详情读取失败",
                        detail: "\(persistedJob.title)：\(error.localizedDescription)"
                    )
                }
            }

            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ),
            let currentTargets = try? resolvedJobSearchTargets(store: store),
            jobSearchPlanFingerprint(
                accountID: account.id,
                targets: currentTargets,
                store: store
            ) == searchPlanFingerprint else { return .unavailable }
            let listings = remoteJobs.map {
                $0.listing(
                    accountID: account.id,
                    detailFetchedAt: detailFetchedAtByRemoteKey[$0.stableRemoteKey]
                )
            }
            store.upsertJobs(listings + hydratedPersistedListings)
            if store.snapshot.automation.automaticallyAssessJobs {
                _ = await store.assessPendingJobsLocally(accountID: account.id)
            }
            guard operationIsCurrent(accountID: account.id, generation: operationGeneration,
                                     store: store, session: session, identityRevision: identityRevision),
                  let latestTargets = try? resolvedJobSearchTargets(store: store),
                  jobSearchPlanFingerprint(accountID: account.id, targets: latestTargets, store: store) == searchPlanFingerprint
            else { return .unavailable }
            if !detailBacklogOnly {
                store.updateAutomation {
                    $0.recordCompletedJobSearchPage(
                        accountID: account.id,
                        planFingerprint: searchPlanFingerprint,
                        completedPage: searchPage
                    )
                }
            }
            // 岗位与下一页游标一起保存；保存失败时重读当前页，避免漏页。
            store.flush()

            if useCodex,
               store.snapshot.codex.enableJobAssessment,
               store.snapshot.codex.allowJobDataToCodex {
                let candidateLimit = allowExternalActions ? 1 : 3
                let fetchedListings = detailIndices.map { listings[$0] } + hydratedPersistedListings
                let fetchedJobIDs = Set(fetchedListings.map(\.id))
                let candidates = fetchedListings.compactMap { listing in
                    store.snapshot.jobs.first(where: { $0.id == listing.id })
                }.filter {
                    fetchedJobIDs.contains($0.id) &&
                        $0.stage == .recommended &&
                        $0.hasAuthoritativeDescription
                }.prefix(candidateLimit)
                if backgroundAssessments[account.id] == nil, let candidate = candidates.first {
                    backgroundAssessments[account.id] = Task { @MainActor [weak self, weak store, weak session] in
                        guard let self, let store, let session else { return }
                        defer { self.backgroundAssessments[account.id] = nil }
                        await codex.assess(
                            jobID: candidate.id, accountID: account.id, using: store,
                            isStillValid: { [weak self, weak store, weak session] in
                                guard let self, let store, let session else { return false }
                                return self.connectorRequestsAllowed(accountID: account.id, store: store) &&
                                    self.operationIsCurrent(
                                        accountID: account.id, generation: operationGeneration,
                                        store: store, session: session, identityRevision: identityRevision
                                    )
                            }
                        )
                    }
                }
            }

            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else { return .unavailable }
            if startupQuickPass {
                lastSearchAtByAccount[account.id] = Date()
                detailBacklogAttemptAtByAccount[account.id] = Date()
            } else if !detailBacklogOnly {
                lastSearchAtByAccount[account.id] = Date()
            }
            let queuedCount = store.queuedAutomaticGreetingCandidateCount(accountID: account.id)
            let hasRemainingDetailBacklog = pendingDetailCount > detailReadCount
            let dailyLimitReached = store.automaticGreetingCountToday(accountID: account.id) >=
                store.snapshot.automation.dailyGreetingLimit
            statusByAccount[account.id] = dailyLimitReached && queuedCount > 0
                ? "已缓存 \(queuedCount) 个待开聊岗位；今日已达上限，明日继续"
                : "已同步 \(listings.count) 个岗位，待开聊 \(queuedCount) 个"
            store.addActivity(
                accountID: account.id,
                level: .success,
                title: startupQuickPass
                    ? "启动首批岗位处理完成"
                    : hasRemainingDetailBacklog ? "BOSS 岗位详情分批完成" : "BOSS 岗位检索完成",
                detail: startupQuickPass
                    ? "首批岗位已经显示；本轮读取 \(detailReadCount) 个详情；合格候选优先开聊，Codex 在后台细评。"
                    : hasRemainingDetailBacklog
                    ? "本批读取 \(detailReadCount) 个岗位详情，剩余 \(pendingDetailCount - detailReadCount) 个按需继续；待开聊 \(queuedCount) 个。"
                    : "按 \(activeSearchTargets.map { "\($0.query)·\($0.city)" }.joined(separator: "、")) 检索第 \(searchPage) 页并保存 \(listings.count) 个岗位。"
            )
            return .performed
        } catch is CancellationError {
            return .unavailable
        } catch {
            await handle(error, account: account, session: session, store: store, operationGeneration: operationGeneration)
            return .unavailable
        }
    }

    @discardableResult
    func synchronizeMessages(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        allowExternalActions: Bool = false
    ) async -> AccountOperationOutcome {
        guard store.snapshot.accounts.contains(where: { $0.id == account.id && $0.status == .active }) else { return .unavailable }
        guard connectorRequestsAllowed(accountID: account.id, store: store) else { return .unavailable }
        guard store.snapshot.automation.allowsConnectorReads else {
            store.report(BossAutomationError.connectorReadsDisabled)
            return .unavailable
        }
        guard await ensureProfileBinding(account: account, session: session, store: store) else { return .unavailable }
        guard let identityRevision = session.currentIdentityRevision(requiringProfileBinding: true) else { return .unavailable }
        guard let operationGeneration = beginOperation(accountID: account.id, profileID: account.webProfileID) else { return .busy }
        defer { finishOperation(accountID: account.id, generation: operationGeneration) }
        readyResumeBacklogAccountIDs.remove(account.id)
        do {
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else { return .unavailable }
            guard try session.credential().isAutomationReady else {
                throw BossAutomationError.incompleteWebCredential
            }
            for resumeExchanges in [false, true] {
                let lastSyncedAt = resumeExchanges
                    ? store.dailyResumeExchangeLastSyncedAt(accountID: account.id)
                    : store.dailyCommunicationLastSyncedAt(accountID: account.id)
                guard lastSyncedAt.map({
                    Date().timeIntervalSince($0) >= AutomationWorkerSchedulePolicy.pollingCeilingSeconds
                }) ?? true else { continue }
                do {
                    _ = try await refreshDailyInteractions(
                        account: account, session: session, store: store,
                        generation: operationGeneration, identityRevision: identityRevision,
                        credential: try session.credential(), resumeExchanges: resumeExchanges
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    switch error {
                    case BossAPIError.invalidPayload: break
                    case BossAPIError.authenticationRequired, BossAPIError.webTokenExpired: throw error
                    default:
                        if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    }
                    store.addActivity(accountID: account.id, level: .warning,
                                      title: resumeExchanges ? "今日交换统计待核对" : "今日沟通统计待核对",
                                      detail: "继续读取已有消息与处理简历交换。\(error.localizedDescription)")
                }
            }
            let profileID = session.profileID
            statusByAccount[account.id] = "正在从 BOSS 消息页读取沟通列表"
            let pageSummaries = try await resumeExchange.pageConversationSummaries(
                profileID: profileID
            )
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else { return .unavailable }
            var incomingSummaries = store.upsertBossFriendSummaries(
                pageSummaries,
                accountID: account.id
            )
            store.pruneUnrouteableBossConversationPlaceholders(accountID: account.id)
            var seenFriendIDs = Set<String>()
            let knownFriendIDs = store.snapshot.conversations
                .filter { $0.accountID == account.id && $0.groupID?.nilIfBlank == nil }
                .compactMap { $0.encryptedBossID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
                .filter { seenFriendIDs.insert($0).inserted }
            if !allowExternalActions, !knownFriendIDs.isEmpty {
                do {
                    let rawFriendList = try await resumeExchange.friendSummariesRaw(
                        profileID: profileID,
                        friendIDs: knownFriendIDs
                    )
                    guard operationIsCurrent(
                        accountID: account.id,
                        generation: operationGeneration,
                        store: store,
                        session: session,
                        identityRevision: identityRevision
                    ) else { return .unavailable }
                    let friendPayload = try JSONSerialization.jsonObject(with: rawFriendList)
                    let enrichedSummaries = try BossPayloadParser.validatedFriendSummaries(
                        from: friendPayload
                    )
                    incomingSummaries += store.upsertBossFriendSummaries(
                        enrichedSummaries,
                        accountID: account.id
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as BossResumeExchangeError {
                    if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    if case .unauthenticated = error { throw error }
                    if case .APIError(_, let code, _) = error,
                       code == 37 || BossServerFailurePolicy.requiresManualVerification(code) {
                        throw error
                    }
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "BOSS 沟通资料补全未完成",
                        detail: "已从 BOSS 消息页取得会话，但招聘方资料补全本轮失败；完整历史仍会继续读取。"
                    )
                } catch {
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "BOSS 沟通资料补全未完成",
                        detail: "已从 BOSS 消息页取得会话，但补全响应无法识别；完整历史仍会继续读取。"
                    )
                }
            }
            guard let remoteIdentityID = store.snapshot.accounts.first(where: {
                $0.id == account.id && $0.status == .active
            })?.remoteProfile?.remoteID.nilIfBlank else { return .unavailable }
            let validRoutes = historyRoutes(accountID: account.id, store: store)
            let routes = historyRoutesForSynchronization(accountID: account.id, store: store,
                limit: allowExternalActions ? 3 : 20)
            let accountConversationCount = store.snapshot.conversations.filter {
                $0.accountID == account.id
            }.count
            let deferredHistoryRouteCount = max(0, validRoutes.count - routes.count)
            var insertedHistoryMessages = 0
            var confirmedResumeDeliveries = 0
            var historyReadFailureCount = max(0, accountConversationCount - validRoutes.count)
            var hasDeferredHistoryBackfill = false
            var resumeDispatchOutcome: ResumeDispatchOutcome = .noAction
            for route in routes {
                try Task.checkCancellation()
                guard operationIsCurrent(
                    accountID: account.id,
                    generation: operationGeneration,
                    store: store,
                    session: session,
                    identityRevision: identityRevision
                ) else { return .unavailable }
                do {
                    var cursorState = store.historyConversationSyncState(
                        accountID: account.id,
                        conversationID: route.conversationID
                    ) ?? BossHistoryConversationSyncState(
                        accountID: account.id,
                        remoteIdentityID: remoteIdentityID,
                        conversationID: route.conversationID,
                        latestHeadMID: nil,
                        gapCursorMID: nil,
                        gapTargetMID: nil,
                        gapNewHeadMID: nil,
                        gapNextPage: 1,
                        backfillCursorMID: nil,
                        backfillNextPage: 1,
                        updatedAt: Date()
                    )
                    if cursorState.gapCursorMID != nil,
                       Self.validatedHistoryContinuationPage(cursorState.gapNextPage) == nil {
                        cursorState.gapCursorMID = nil
                        cursorState.gapTargetMID = nil
                        cursorState.gapNewHeadMID = nil
                        cursorState.gapNextPage = 1
                        historyReadFailureCount += 1
                    }
                    if cursorState.backfillCursorMID != nil,
                       Self.validatedHistoryContinuationPage(cursorState.backfillNextPage) == nil {
                        cursorState.backfillCursorMID = nil
                        cursorState.backfillNextPage = 1
                        historyReadFailureCount += 1
                    }
                    var lane: HistoryReadLane = cursorState.gapCursorMID == nil ? .head : .gap
                    var maximumMessageID = cursorState.gapCursorMID ?? "0"
                    var requestPage = lane == .gap ? cursorState.gapNextPage : 1
                    if allowExternalActions, lane == .head,
                       Self.shouldReadHistoryBackfill(
                           latestHeadMID: cursorState.latestHeadMID,
                           backfillCursorMID: cursorState.backfillCursorMID,
                           latestSummaryMID: store.snapshot.conversations.first {
                               $0.accountID == account.id && $0.id == route.conversationID
                           }?.messages.max(by: { $0.sentAt < $1.sentAt })?.remoteMID
                       ), let backfill = cursorState.backfillCursorMID {
                        lane = .backfill
                        maximumMessageID = backfill
                        requestPage = cursorState.backfillNextPage
                    }
                    for _ in 0..<(allowExternalActions ? 1 : 2) {
                        let page = try await resumeExchange.history(
                            profileID: profileID,
                            query: BossResumeHistoryQuery(
                                bossID: route.bossID,
                                groupID: route.groupID,
                                maximumMessageID: maximumMessageID,
                                count: 50,
                                page: requestPage,
                                source: route.source,
                                securityID: route.securityID,
                                gid: route.groupID
                            )
                        )
                        guard operationIsCurrent(
                            accountID: account.id,
                            generation: operationGeneration,
                            store: store,
                            session: session,
                            identityRevision: identityRevision
                        ) else { return .unavailable }
                        let outcome = store.upsertBossHistoryMessages(
                            messages: page.messages,
                            accountID: account.id,
                            conversationID: route.conversationID,
                            authoritativeCurrentUserID: page.currentUserID
                        )
                        insertedHistoryMessages += outcome.insertedMessageCount
                        confirmedResumeDeliveries += try reconcileNativeResumeDeliveries(
                            accountID: account.id,
                            conversationID: route.conversationID,
                            store: store
                        )
                        let pageMessageIDs = Set(page.messages.compactMap {
                            ResumeDeliveryDigestPolicy.normalizedRemoteMID($0.messageID)
                        })
                        var shouldStopPaging = false

                        switch lane {
                        case .head:
                            let newestHeadMID = Self.newestHistoryMessageMID(page.messages)
                            if !page.messages.isEmpty, newestHeadMID == nil {
                                historyReadFailureCount += 1
                                shouldStopPaging = true
                                break
                            }
                            if !page.hasMore {
                                cursorState.latestHeadMID = newestHeadMID ?? cursorState.latestHeadMID
                                cursorState.gapCursorMID = nil
                                cursorState.gapTargetMID = nil
                                cursorState.gapNewHeadMID = nil
                                cursorState.gapNextPage = 1
                                cursorState.backfillCursorMID = nil
                                cursorState.backfillNextPage = 1
                                shouldStopPaging = true
                                break
                            }

                            let previousHeadMID = cursorState.latestHeadMID
                            let overlapsPreviousHead = previousHeadMID == nil ||
                                previousHeadMID.map(pageMessageIDs.contains) == true
                            if overlapsPreviousHead {
                                cursorState.latestHeadMID = newestHeadMID ?? previousHeadMID
                                if let backfill = cursorState.backfillCursorMID {
                                    maximumMessageID = backfill
                                    requestPage = cursorState.backfillNextPage
                                } else if let next = validatedHistoryCursor(
                                    page.minimumMessageID,
                                    differentFrom: maximumMessageID
                                ), let nextPage = Self.nextHistoryPage(after: requestPage) {
                                    cursorState.backfillCursorMID = next
                                    cursorState.backfillNextPage = nextPage
                                    maximumMessageID = next
                                    requestPage = nextPage
                                } else {
                                    historyReadFailureCount += 1
                                    shouldStopPaging = true
                                    break
                                }
                                lane = .backfill
                            } else if let previousHeadMID,
                                      let next = validatedHistoryCursor(
                                        page.minimumMessageID,
                                        differentFrom: maximumMessageID
                                      ), let nextPage = Self.nextHistoryPage(after: requestPage) {
                                // 先补齐最新消息间的缺口，再推进旧历史游标。
                                cursorState.gapCursorMID = next
                                cursorState.gapTargetMID = previousHeadMID
                                cursorState.gapNewHeadMID = newestHeadMID
                                cursorState.gapNextPage = nextPage
                                maximumMessageID = next
                                requestPage = nextPage
                                lane = .gap
                            } else {
                                historyReadFailureCount += 1
                                shouldStopPaging = true
                                break
                            }

                        case .gap:
                            let reachedTarget = cursorState.gapTargetMID
                                .map(pageMessageIDs.contains) == true
                            if reachedTarget || !page.hasMore {
                                cursorState.latestHeadMID = cursorState.gapNewHeadMID ??
                                    cursorState.latestHeadMID
                                cursorState.gapCursorMID = nil
                                cursorState.gapTargetMID = nil
                                cursorState.gapNewHeadMID = nil
                                cursorState.gapNextPage = 1
                                shouldStopPaging = true
                                break
                            }
                            guard let next = validatedHistoryCursor(
                                page.minimumMessageID,
                                differentFrom: maximumMessageID
                            ), let nextPage = Self.nextHistoryPage(after: requestPage) else {
                                cursorState.gapCursorMID = nil
                                cursorState.gapTargetMID = nil
                                cursorState.gapNewHeadMID = nil
                                cursorState.gapNextPage = 1
                                historyReadFailureCount += 1
                                shouldStopPaging = true
                                break
                            }
                            cursorState.gapCursorMID = next
                            cursorState.gapNextPage = nextPage
                            maximumMessageID = next
                            requestPage = nextPage

                        case .backfill:
                            if page.hasMore {
                                guard let next = validatedHistoryCursor(
                                    page.minimumMessageID,
                                    differentFrom: maximumMessageID
                                ), let nextPage = Self.nextHistoryPage(after: requestPage) else {
                                    cursorState.backfillCursorMID = nil
                                    cursorState.backfillNextPage = 1
                                    historyReadFailureCount += 1
                                    shouldStopPaging = true
                                    break
                                }
                                cursorState.backfillCursorMID = next
                                cursorState.backfillNextPage = nextPage
                            } else {
                                cursorState.backfillCursorMID = nil
                                cursorState.backfillNextPage = 1
                            }
                            shouldStopPaging = true
                            break
                        }

                        cursorState.updatedAt = Date()
                        store.saveHistoryConversationSyncState(cursorState)
                        if shouldStopPaging {
                            break
                        }
                    }
                    cursorState.updatedAt = Date()
                    store.saveHistoryConversationSyncState(cursorState)
                    if cursorState.gapCursorMID != nil || cursorState.backfillCursorMID != nil {
                        hasDeferredHistoryBackfill = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as BossResumeExchangeError {
                    if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                    if case .unauthenticated = error { throw error }
                    if case .APIError(_, let code, _) = error,
                       code == 37 || BossServerFailurePolicy.requiresManualVerification(code) {
                        throw error
                    }
                    historyReadFailureCount += 1
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "BOSS 完整消息读取未完成",
                        detail: "会话历史本轮未读取，已跳过该会话；不会根据摘要发送简历。"
                    )
                }
                if allowExternalActions, resumeDispatchOutcome == .noAction {
                    resumeDispatchOutcome = await dispatchNextAutomaticResumeIfNeeded(
                        account: account, session: session, store: store,
                        operationGeneration: operationGeneration, identityRevision: identityRevision
                    )
                    if resumeDispatchOutcome.abortsMessageSynchronization { return .unavailable }
                }
            }

            if allowExternalActions, resumeDispatchOutcome == .noAction {
                resumeDispatchOutcome = await dispatchNextAutomaticResumeIfNeeded(
                    account: account,
                    session: session,
                    store: store,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision
                )
            }
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ), !resumeDispatchOutcome.abortsMessageSynchronization else {
                return .unavailable
            }
            store.markAccountSynced(accountID: account.id)
            lastMessageSyncAtByAccount[account.id] = Date()
            // 仅成功提交后加快下一次同步，失败继续使用普通退避。
            if allowExternalActions, case .completed = resumeDispatchOutcome,
               !store.authoritativeResumeConsentCandidates(accountID: account.id).isEmpty {
                readyResumeBacklogAccountIDs.insert(account.id)
            } else {
                readyResumeBacklogAccountIDs.remove(account.id)
            }
            let totalNewMessages = max(incomingSummaries, insertedHistoryMessages)
            let historySyncCompletion = Self.historySyncCompletion(
                historyReadFailureCount: historyReadFailureCount,
                deferredRouteCount: deferredHistoryRouteCount,
                hasDeferredBackfill: hasDeferredHistoryBackfill
            )
            let historySyncIsPartial: Bool
            if case .partial = historySyncCompletion {
                historySyncIsPartial = true
            } else {
                historySyncIsPartial = false
            }
            if case .requiresAttention = resumeDispatchOutcome,
               let status = resumeDispatchOutcome.status {
                statusByAccount[account.id] = status
            } else if confirmedResumeDeliveries > 0 {
                statusByAccount[account.id] = "已回读确认 \(confirmedResumeDeliveries) 份附件简历"
            } else if let status = resumeDispatchOutcome.status {
                statusByAccount[account.id] = status
            } else if historySyncIsPartial {
                statusByAccount[account.id] = historyReadFailureCount > 0
                    ? "本轮有 \(historyReadFailureCount) 个会话读取失败，其余待续传"
                    : "本轮同步 \(routes.count)/\(validRoutes.count) 个会话，其余待续传"
            } else {
                statusByAccount[account.id] = totalNewMessages > 0
                    ? "发现 \(totalNewMessages) 条新消息"
                    : "BOSS 消息本轮已同步"
            }
            store.addActivity(
                accountID: account.id,
                level: historySyncIsPartial ? .warning : .success,
                title: historySyncIsPartial ? "BOSS 沟通本轮部分同步" : "BOSS 沟通本轮已同步",
                detail: historySyncIsPartial
                    ? "新增 \(insertedHistoryMessages) 条完整历史消息；读取失败 \(historyReadFailureCount) 个、轮转待同步 \(deferredHistoryRouteCount) 个，分页待续传：\(hasDeferredHistoryBackfill ? "是" : "否")。"
                    : (totalNewMessages > 0
                        ? "新增 \(insertedHistoryMessages) 条完整历史消息，最近摘要新增 \(incomingSummaries) 条；本轮读取 \(routes.count)/\(validRoutes.count) 个可用会话。"
                        : "未发现新的招聘方消息；本轮读取 \(routes.count)/\(validRoutes.count) 个可用会话。")
            )
            return .performed
        } catch is CancellationError {
            return .unavailable
        } catch let error as BossResumeExchangeError {
            await handleResumeExchangeReadError(
                error,
                account: account,
                session: session,
                store: store,
                operationGeneration: operationGeneration,
                identityRevision: identityRevision
            )
            return .unavailable
        } catch {
            await handle(error, account: account, session: session, store: store, operationGeneration: operationGeneration)
            return .unavailable
        }
    }

    private func historyRoutes(accountID: UUID, store: AppStore) -> [BossHistoryRoute] {
        let unresolvedConversationIDs = unresolvedResumeDeliveryConversationIDs(
            accountID: accountID,
            store: store
        )
        return store.snapshot.conversations
            .filter { $0.accountID == accountID }
            .sorted { lhs, rhs in
                let leftIsUnresolved = unresolvedConversationIDs.contains(lhs.id) ||
                    lhs.remoteConversationID.map(unresolvedConversationIDs.contains) == true
                let rightIsUnresolved = unresolvedConversationIDs.contains(rhs.id) ||
                    rhs.remoteConversationID.map(unresolvedConversationIDs.contains) == true
                if leftIsUnresolved != rightIsUnresolved { return leftIsUnresolved }
                let left = lhs.remoteUpdatedAt ?? lhs.lastSyncedAt
                let right = rhs.remoteUpdatedAt ?? rhs.lastSyncedAt
                if left != right { return left > right }
                return lhs.id < rhs.id
            }
            .compactMap { conversation in
                let groupID = conversation.groupID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).nilIfBlank
                if let groupID {
                    // 群聊历史仅按 gid 路由，不能因缺少单聊字段而丢弃。
                    return BossHistoryRoute(
                        conversationID: conversation.id,
                        bossID: "",
                        securityID: "",
                        source: 0,
                        groupID: groupID
                    )
                }
                guard let bossID = conversation.encryptedBossID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).nilIfBlank,
                let securityID = conversation.securityID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).nilIfBlank,
                let source = Self.validatedHistorySource(conversation.friendSource) else {
                    return nil
                }
                return BossHistoryRoute(
                    conversationID: conversation.id,
                    bossID: bossID,
                    securityID: securityID,
                    source: source,
                    groupID: nil
                )
            }
    }

    nonisolated static func validatedHistorySource(_ value: String?) -> Int? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let source = Int(normalized),
              source >= 0 else {
            return nil
        }
        return source
    }

    nonisolated static func historySyncCompletion(
        historyReadFailureCount: Int,
        deferredRouteCount: Int = 0,
        hasDeferredBackfill: Bool = false
    ) -> HistorySyncCompletion {
        let failures = max(0, historyReadFailureCount)
        let deferred = max(0, deferredRouteCount)
        let incompleteCount = failures + deferred + (hasDeferredBackfill ? 1 : 0)
        return incompleteCount == 0
            ? .complete
            : .partial(failedRouteCount: incompleteCount)
    }

    /// 补缺和回填游标必须携带续页页码；第一页始终用于最新消息。
    nonisolated static func validatedHistoryContinuationPage(_ page: Int) -> Int? {
        page >= 2 ? page : nil
    }

    nonisolated static func shouldReadHistoryBackfill(
        latestHeadMID: String?, backfillCursorMID: String?, latestSummaryMID: String?
    ) -> Bool {
        guard backfillCursorMID != nil,
              let head = ResumeDeliveryDigestPolicy.normalizedRemoteMID(latestHeadMID),
              let summary = ResumeDeliveryDigestPolicy.normalizedRemoteMID(latestSummaryMID) else { return false }
        return head == summary || ResumeDeliveryDigestPolicy.remoteMID(head, isStrictlyNewerThan: summary)
    }

    /// 历史续读同时推进 maxMsgId 和 page；溢出时停止，避免重复页码。
    nonisolated static func nextHistoryPage(after currentPage: Int) -> Int? {
        guard currentPage >= 1, currentPage < Int.max else { return nil }
        return currentPage + 1
    }

    /// 招聘方原生索要卡片与候选人确认流程使用不同的附件来源。
    nonisolated static func attachmentListFrom(
        for exchangeKind: BossResumeExchangeKind
    ) -> Int {
        exchangeKind == .acceptNativeRequest ? 3 : 2
    }

    /// 为普通会话保留预算，避免待确认投递长期占满同步周期。
    nonisolated static func historySynchronizationBudgets(
        unresolvedCount: Int,
        regularCount: Int,
        limit: Int
    ) -> (unresolved: Int, regular: Int) {
        let unresolvedCount = max(0, unresolvedCount)
        let regularCount = max(0, regularCount)
        let limit = max(0, limit)
        guard limit > 0 else { return (0, 0) }
        guard unresolvedCount > 0 else { return (0, min(regularCount, limit)) }
        guard regularCount > 0 else { return (min(unresolvedCount, limit), 0) }

        // 预算仅一条时分配给普通会话，保证其仍有机会同步。
        guard limit > 1 else { return (0, 1) }

        let reservedRegular = min(regularCount, max(1, limit / 2))
        var selectedUnresolved = min(unresolvedCount, limit - reservedRegular)
        var selectedRegular = min(regularCount, limit - selectedUnresolved)
        var remaining = limit - selectedUnresolved - selectedRegular
        if remaining > 0 {
            let additionalUnresolved = min(unresolvedCount - selectedUnresolved, remaining)
            selectedUnresolved += additionalUnresolved
            remaining -= additionalUnresolved
        }
        if remaining > 0 {
            selectedRegular += min(regularCount - selectedRegular, remaining)
        }
        return (selectedUnresolved, selectedRegular)
    }

    nonisolated static func automaticResumeCommitSettingsAllow(
        isAutomaticMode: Bool,
        allowsExternalActions: Bool,
        automaticallyMonitorsMessages: Bool,
        automaticallySendsResume: Bool
    ) -> Bool {
        isAutomaticMode &&
            allowsExternalActions &&
            automaticallyMonitorsMessages &&
            automaticallySendsResume
    }

    nonisolated static func remoteResumeBindingIsUsable(
        remoteResumeToken: String,
        attachments: [BossResumeAttachment]
    ) -> Bool {
        let token = remoteResumeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let exactMatches = attachments.filter { attachment in
            attachment.resumeToken == token
        }
        guard exactMatches.count == 1, let attachment = exactMatches.first else {
            return false
        }
        return attachment.annexType == 0 && !attachment.isRestricted
    }

    /// 仅自动选择唯一且未受限的 annexType=0 简历，多个附件时交由用户处理。
    nonisolated static func uniqueBossMaintainedResumeAttachment(
        in attachments: [BossResumeAttachment]
    ) -> BossResumeAttachment? {
        let usable = attachments.filter { $0.annexType == 0 && !$0.isRestricted }
        guard usable.count == 1 else { return nil }
        return usable[0]
    }

    nonisolated static func nativeEvidenceMayCreateSeparateDelivery(
        exchangeKind: BossResumeExchangeKind,
        hasRelatedType3Delivery: Bool
    ) -> Bool {
        !(exchangeKind == .acceptNativeRequest && hasRelatedType3Delivery)
    }

    /// 仅以同账号、同会话中时间晚于原请求的唯一原生卡片推进投递；有歧义时拒绝。
    nonisolated static func uniquelyPromotableType3RecordID(
        for evidence: ResumeConsentEvidence,
        records: [ResumeDeliveryRecord]
    ) -> String? {
        guard evidence.isAuthoritativeNativeRequest else { return nil }
        let matches = records.filter { record in
            record.accountID == evidence.accountID &&
                record.remoteIdentityID == evidence.remoteIdentityID &&
                record.conversationID == evidence.conversationID &&
                record.exchangeKind == .requestRecruiterConfirmation &&
                record.state == .requestCreatedAwaitingRecruiter &&
                record.serverAcceptedAt.map { evidence.receivedAt >= $0 } == true &&
                ResumeDeliveryDigestPolicy.remoteMID(
                    evidence.triggerRemoteMID,
                    isStrictlyNewerThan: record.writeBaselineRemoteMID ?? record.triggerRemoteMID
                )
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    private func validatedHistoryCursor(
        _ value: String?,
        differentFrom current: String
    ) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty,
              normalized != current,
              normalized.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        return normalized
    }

    private func unresolvedResumeDeliveryConversationIDs(
        accountID: UUID,
        store: AppStore
    ) -> Set<String> {
        guard let remoteIdentityID = store.snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.nilIfBlank else { return [] }
        return Set(store.snapshot.resumeDeliveryRecords.compactMap { record -> String? in
            guard record.accountID == accountID,
                  record.remoteIdentityID == remoteIdentityID,
                  record.state == .queued ||
                    record.state == .preparingAttachment ||
                    record.state == .dispatching ||
                    record.state == .requestCreatedAwaitingRecruiter ||
                    record.state == .serverAcceptedUnverified else {
                return nil
            }
            return record.conversationID
        })
    }

    func historyRoutesForSynchronization(
        accountID: UUID,
        store: AppStore,
        limit: Int = 20
    ) -> [BossHistoryRoute] {
        guard limit > 0 else { return [] }
        let allRoutes = historyRoutes(accountID: accountID, store: store).sorted {
            $0.conversationID < $1.conversationID
        }
        var priorityRoutes: [BossHistoryRoute] = []
        if limit < 20 {
            let routesByID = Dictionary(allRoutes.map { ($0.conversationID, $0) }, uniquingKeysWith: { first, _ in first })
            let remoteIdentityID = store.snapshot.accounts.first {
                $0.id == accountID && $0.status == .active
            }?.remoteProfile?.remoteID.nilIfBlank
            let headsByID = Dictionary(store.snapshot.historyConversationSyncStates
                .filter { $0.accountID == accountID && $0.remoteIdentityID == remoteIdentityID }
                .map { ($0.conversationID, $0.latestHeadMID) }, uniquingKeysWith: { first, _ in first })
            priorityRoutes = store.snapshot.conversations.filter { conversation in
                guard conversation.accountID == accountID,
                      let latest = conversation.messages.max(by: { $0.sentAt < $1.sentAt }),
                      latest.direction == .incoming,
                      let mid = latest.remoteMID else { return false }
                return headsByID[conversation.id] != mid
            }.sorted { ($0.remoteUpdatedAt ?? .distantPast) > ($1.remoteUpdatedAt ?? .distantPast) }
                .compactMap { routesByID[$0.id] }.prefix(1).map { $0 }
        }
        let priorityIDs = Set(priorityRoutes.map(\.conversationID))
        let remainingRoutes = allRoutes.filter { !priorityIDs.contains($0.conversationID) }
        let unresolvedConversationIDs = unresolvedResumeDeliveryConversationIDs(
            accountID: accountID,
            store: store
        )
        let unresolvedRoutes = remainingRoutes.filter {
            unresolvedConversationIDs.contains($0.conversationID)
        }
        let regularRoutes = remainingRoutes.filter {
            !unresolvedConversationIDs.contains($0.conversationID)
        }
        let budgets = Self.historySynchronizationBudgets(
            unresolvedCount: unresolvedRoutes.count,
            regularCount: regularRoutes.count,
            limit: limit - priorityRoutes.count
        )
        let persistedRotation = store.historyRouteRotationState(accountID: accountID)
        var unresolvedOffset = persistedRotation?.unresolvedOffset ?? 0
        var regularOffset = persistedRotation?.regularOffset ?? 0
        let selectedUnresolved = rotatedHistoryRoutes(
            unresolvedRoutes,
            limit: budgets.unresolved,
            offset: &unresolvedOffset
        )
        let selectedRegular = rotatedHistoryRoutes(
            regularRoutes,
            limit: budgets.regular,
            offset: &regularOffset
        )
        store.saveHistoryRouteRotationState(
            accountID: accountID,
            unresolvedOffset: unresolvedOffset,
            regularOffset: regularOffset
        )
        return priorityRoutes + selectedUnresolved + selectedRegular
    }

    private func rotatedHistoryRoutes(
        _ routes: [BossHistoryRoute],
        limit: Int,
        offset: inout Int
    ) -> [BossHistoryRoute] {
        let rotation = Self.rotatedHistoryRouteIndices(
            routeCount: routes.count,
            limit: limit,
            offset: offset
        )
        offset = rotation.nextOffset
        return rotation.indices.map { routes[$0] }
    }

    nonisolated static func rotatedHistoryRouteIndices(
        routeCount: Int,
        limit: Int,
        offset: Int
    ) -> (indices: [Int], nextOffset: Int) {
        guard routeCount > 0, limit > 0 else { return ([], 0) }
        let normalizedOffset = ((offset % routeCount) + routeCount) % routeCount
        let selectedCount = min(limit, routeCount)
        let indices = (0..<selectedCount).map {
            (normalizedOffset + $0) % routeCount
        }
        return (indices, (normalizedOffset + selectedCount) % routeCount)
    }

    private func historyRoute(
        accountID: UUID,
        conversationID: String,
        store: AppStore
    ) -> BossHistoryRoute? {
        historyRoutes(accountID: accountID, store: store).first {
            $0.conversationID == conversationID
        }
    }

    @discardableResult
    private func reconcileNativeResumeDeliveries(
        accountID: UUID,
        conversationID: String,
        store: AppStore
    ) throws -> Int {
        guard let conversation = store.snapshot.conversations.first(where: {
            $0.accountID == accountID && $0.id == conversationID
        }) else { return 0 }
        let records = store.snapshot.resumeDeliveryRecords.filter {
            $0.accountID == accountID &&
                $0.conversationID == conversationID &&
                (($0.exchangeKind == .acceptNativeRequest &&
                  ($0.state == .dispatching || $0.state == .serverAcceptedUnverified)) ||
                 ($0.exchangeKind == .requestRecruiterConfirmation &&
                  $0.state == .requestCreatedAwaitingRecruiter))
        }
        var confirmed = 0
        for record in records {
            let hasAuthoritativeReadback: Bool
            switch record.exchangeKind {
            case .acceptNativeRequest:
                hasAuthoritativeReadback = Self.nativeResumeDeliveryHasAuthoritativeReadback(
                    record: record,
                    messages: conversation.messages
                )
            case .requestRecruiterConfirmation:
                hasAuthoritativeReadback = Self.type3ResumeDeliveryHasAuthoritativeReadback(
                    record: record,
                    messages: conversation.messages
                )
            }
            guard hasAuthoritativeReadback else { continue }
            _ = try store.transitionResumeDelivery(
                recordID: record.id,
                to: .confirmed,
                remoteResumeToken: record.remoteResumeToken
            )
            confirmed += 1
        }
        return confirmed
    }

    nonisolated static func nativeResumeDeliveryHasAuthoritativeReadback(
        record: ResumeDeliveryRecord,
        messages: [ChatMessage]
    ) -> Bool {
        guard record.exchangeKind == .acceptNativeRequest,
              record.state == .dispatching || record.state == .serverAcceptedUnverified else {
            return false
        }
        return resumeDeliveryHasAuthoritativeAttachmentReadback(
            record: record,
            messages: messages
        )
    }

    nonisolated static func type3ResumeDeliveryHasAuthoritativeReadback(
        record: ResumeDeliveryRecord,
        messages: [ChatMessage]
    ) -> Bool {
        guard record.exchangeKind == .requestRecruiterConfirmation,
              record.state == .requestCreatedAwaitingRecruiter else {
            return false
        }
        return resumeDeliveryHasAuthoritativeAttachmentReadback(
            record: record,
            messages: messages
        )
    }

    nonisolated static func resumeDeliveryHasAuthoritativeAttachmentReadback(
        record: ResumeDeliveryRecord,
        messages: [ChatMessage]
    ) -> Bool {
        guard let remoteResumeToken = record.remoteResumeToken?.nilIfBlank else { return false }
        let writeStartedAt = record.writeStartedAt ?? record.createdAt
        let lowerBound = writeStartedAt.addingTimeInterval(-5)
        let baselineMID = record.writeBaselineRemoteMID?.nilIfBlank ?? record.triggerRemoteMID
        return messages.contains { message in
            guard message.isAuthoritativeHistoryRecord == true &&
                message.hasAuthoritativeDirection == true &&
                message.direction == .outgoing &&
                message.remoteBodyType == 12 &&
                message.hyperLinkType == 1 &&
                message.hyperLinkResumeToken == remoteResumeToken &&
                message.sentAt >= lowerBound,
                let outgoingMID = message.remoteMID?.nilIfBlank else {
                return false
            }
            return remoteMID(outgoingMID, isStrictlyNewerThan: baselineMID)
        }
    }

    nonisolated static func newestAuthoritativeNumericRemoteMID(
        in messages: [ChatMessage]
    ) -> String? {
        messages.compactMap { message -> String? in
            guard message.isAuthoritativeHistoryRecord == true else { return nil }
            return normalizedNumericRemoteMID(message.remoteMID)
        }.max { lhs, rhs in
            remoteMID(rhs, isStrictlyNewerThan: lhs)
        }
    }

    nonisolated static func newestHistoryMessageMID(
        _ messages: [BossResumeHistoryMessage]
    ) -> String? {
        messages.compactMap {
            ResumeDeliveryDigestPolicy.normalizedRemoteMID($0.messageID)
        }.max { lhs, rhs in
            ResumeDeliveryDigestPolicy.remoteMID(rhs, isStrictlyNewerThan: lhs)
        }
    }

    nonisolated static func remoteMID(
        _ candidate: String,
        isStrictlyNewerThan baseline: String
    ) -> Bool {
        guard let candidate = normalizedNumericRemoteMID(candidate),
              let baseline = normalizedNumericRemoteMID(baseline) else { return false }
        if candidate.count != baseline.count { return candidate.count > baseline.count }
        return candidate > baseline
    }

    nonisolated private static func normalizedNumericRemoteMID(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= 32,
              raw.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        let trimmed = raw.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private func dispatchNextAutomaticResumeIfNeeded(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        operationGeneration: UInt64,
        identityRevision: UInt64
    ) async -> ResumeDispatchOutcome {
        guard automaticResumeWritePermitAccountIDs.contains(account.id),
              Self.automaticResumeCommitSettingsAllow(
                isAutomaticMode: store.snapshot.automation.mode == .automatic,
                allowsExternalActions: store.snapshot.automation.allowsExternalActions,
                automaticallyMonitorsMessages: store.snapshot.automation.automaticallyMonitorMessages,
                automaticallySendsResume: store.snapshot.automation.automaticallySendResume
              ),
              let remoteIdentityID = store.snapshot.accounts.first(where: {
                  $0.id == account.id && $0.status == .active
              })?.remoteProfile?.remoteID.nilIfBlank else {
            return .noAction
        }

        let interruptedRecord = store.snapshot.resumeDeliveryRecords
            .filter {
                $0.accountID == account.id &&
                    $0.remoteIdentityID == remoteIdentityID &&
                    ($0.state == .preparingAttachment || $0.state == .dispatching)
            }
            .sorted { $0.createdAt < $1.createdAt }
            .first
        if let interruptedRecord {
            if interruptedRecord.state == .preparingAttachment {
                _ = try? store.transitionResumeDelivery(
                    recordID: interruptedRecord.id,
                    to: .queued
                )
                statusByAccount[account.id] = "上次附件准备未完成，已恢复为可重试"
                return .completed(status: statusByAccount[account.id] ?? "附件准备已恢复")
            } else {
                _ = try? store.transitionResumeDelivery(
                    recordID: interruptedRecord.id,
                    to: .failed,
                    failureCode: .requestOutcomeUnknown
                )
                statusByAccount[account.id] = "上次简历发送结果不确定，已禁止重复发送"
            }
            return .requiresAttention(status: statusByAccount[account.id] ?? "附件简历状态需要人工核验")
        }

        let queuedRecord = store.snapshot.resumeDeliveryRecords
            .filter {
                $0.accountID == account.id &&
                    $0.remoteIdentityID == remoteIdentityID &&
                    $0.state == .queued
            }
            .sorted { $0.createdAt < $1.createdAt }
            .first
        let unresolvedType3Records = store.snapshot.resumeDeliveryRecords.filter { record in
            record.accountID == account.id &&
                record.remoteIdentityID == remoteIdentityID &&
                record.exchangeKind == .requestRecruiterConfirmation &&
                record.state == .requestCreatedAwaitingRecruiter
        }
        let relatedType3ConversationIDs = Set(
            store.snapshot.resumeDeliveryRecords.compactMap { record -> String? in
                guard record.accountID == account.id,
                      record.remoteIdentityID == remoteIdentityID,
                      record.exchangeKind == .requestRecruiterConfirmation,
                      record.state == .requestCreatedAwaitingRecruiter ||
                        record.state == .confirmed else { return nil }
                return record.conversationID
            }
        )
        let consentCandidates = store.authoritativeResumeConsentCandidates(accountID: account.id)
            .sorted { lhs, rhs in
                if lhs.exchangeKind != rhs.exchangeKind {
                    return lhs.exchangeKind == .acceptNativeRequest
                }
                if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt < rhs.receivedAt }
                return lhs.triggerRemoteMID < rhs.triggerRemoteMID
            }
        let promotableEvidence = consentCandidates.filter { candidate in
            Self.uniquelyPromotableType3RecordID(
                for: candidate,
                records: unresolvedType3Records
            ) != nil
        }
        // 歧义仅影响当前会话，不阻塞其他招聘方的有效请求。
        let promotionEvidence = Dictionary(
            grouping: promotableEvidence,
            by: \.conversationID
        ).values
            .compactMap { $0.count == 1 ? $0[0] : nil }
            .sorted { lhs, rhs in
                if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt < rhs.receivedAt }
                return lhs.triggerRemoteMID < rhs.triggerRemoteMID
            }
            .first
        let promotionRecord = promotionEvidence.flatMap { candidate in
            Self.uniquelyPromotableType3RecordID(
                for: candidate,
                records: unresolvedType3Records
            ).flatMap { recordID in
                unresolvedType3Records.first { $0.id == recordID }
            }
        }
        let evidence = consentCandidates
            .first { evidence in
                if promotionEvidence == evidence { return false }
                return Self.nativeEvidenceMayCreateSeparateDelivery(
                    exchangeKind: evidence.exchangeKind,
                    hasRelatedType3Delivery: relatedType3ConversationIDs.contains(
                        evidence.conversationID
                    )
                )
            }
        guard promotionRecord != nil || queuedRecord != nil || evidence != nil else { return .noAction }

        var recordID = promotionRecord?.id ?? queuedRecord?.id
        var stage = ResumeDispatchStage.preparation
        do {
            let selectedRecord = promotionRecord ?? queuedRecord
            guard let conversationID = promotionEvidence?.conversationID ??
                    selectedRecord?.conversationID ?? evidence?.conversationID,
                  let dispatchExchangeKind = promotionEvidence?.exchangeKind ??
                    selectedRecord?.exchangeKind ?? evidence?.exchangeKind,
                  let triggerRemoteMID = promotionEvidence?.triggerRemoteMID ??
                    selectedRecord?.triggerRemoteMID ?? evidence?.triggerRemoteMID else {
                return .noAction
            }
            let nativeScene = promotionEvidence?.nativeScene ??
                selectedRecord?.nativeScene ?? evidence?.nativeScene
            guard let route = historyRoute(
                accountID: account.id,
                conversationID: conversationID,
                store: store
            ) else {
                throw ResumeDeliveryStoreError.conversationMismatch
            }
            let writeBaselineRemoteMID = store.snapshot.conversations.first(where: {
                $0.accountID == account.id && $0.id == conversationID
            }).flatMap {
                Self.newestAuthoritativeNumericRemoteMID(in: $0.messages)
            }

            let exchangePreflight: ResumeExchangePreflight
            switch dispatchExchangeKind {
            case .requestRecruiterConfirmation:
                exchangePreflight = .request(
                    try await resumeExchange.preflightRequestAttachmentResume(
                        profileID: session.profileID,
                        securityID: route.securityID,
                        friendSource: route.source
                    )
                )
            case .acceptNativeRequest:
                exchangePreflight = .accept(
                    try await resumeExchange.preflightAcceptAttachmentResume(
                        profileID: session.profileID,
                        securityID: route.securityID,
                        requestMessageID: triggerRemoteMID
                    )
                )
            }
            guard automaticResumeWriteIsCurrent(
                accountID: account.id,
                remoteIdentityID: remoteIdentityID,
                operationGeneration: operationGeneration,
                identityRevision: identityRevision,
                session: session,
                store: store
            ) else { return .cancelled }

            let attachmentListFrom = Self.attachmentListFrom(for: dispatchExchangeKind)
            let attachments = try await resumeExchange.listAttachments(
                profileID: session.profileID,
                from: attachmentListFrom
            )
            guard automaticResumeWriteIsCurrent(
                accountID: account.id,
                remoteIdentityID: remoteIdentityID,
                operationGeneration: operationGeneration,
                identityRevision: identityRevision,
                session: session,
                store: store
            ) else { return .cancelled }

            var record = selectedRecord
            let binding: BossRemoteResumeBinding
            if let selectedRecord {
                recordID = selectedRecord.id
                guard let currentBinding = store.remoteResumeBinding(
                    accountID: account.id,
                    attachmentSHA256: selectedRecord.attachmentSHA256
                ), Self.remoteResumeBindingIsUsable(
                    remoteResumeToken: currentBinding.remoteResumeToken,
                    attachments: attachments
                ) else {
                    let status = "原投递绑定的 BOSS 附件简历已不可用，本次未发送"
                    statusByAccount[account.id] = status
                    return .requiresAttention(status: status)
                }
                if promotionRecord != nil,
                   selectedRecord.remoteResumeToken?.nilIfBlank != currentBinding.remoteResumeToken {
                    throw ResumeDeliveryStoreError.remoteResumeBindingMissing
                }
                binding = currentBinding
            } else {
                let usableAttachments = attachments.filter {
                    $0.annexType == 0 && !$0.isRestricted
                }
                guard let maintainedAttachment = Self.uniqueBossMaintainedResumeAttachment(
                    in: attachments
                ) else {
                    let status = usableAttachments.isEmpty
                        ? "当前 BOSS 账号没有可用的附件简历，本次未发送"
                        : "当前 BOSS 账号存在多份可用附件简历，无法确定发送哪一份"
                    statusByAccount[account.id] = status
                    return .requiresAttention(status: status)
                }
                let selectorDigest = BossRemoteResumeBinding.selectorDigest(
                    remoteIdentityID: remoteIdentityID,
                    remoteResumeToken: maintainedAttachment.resumeToken
                )
                binding = try store.saveRemoteResumeBinding(
                    BossRemoteResumeBinding(
                        accountID: account.id,
                        remoteIdentityID: remoteIdentityID,
                        attachmentSHA256: selectorDigest,
                        remoteResumeToken: maintainedAttachment.resumeToken,
                        remoteDisplayName: maintainedAttachment.displayName,
                        uploadedAt: Date()
                    )
                )
            }

            let prepareRecordAtFirstWriteCommit: @MainActor () -> ResumeDeliveryRecord? = {
                if let record { return record }
                guard let evidence else { return nil }
                do {
                    let preparedRecord = try store.prepareResumeDelivery(
                        evidence: evidence,
                        attachmentSHA256: binding.attachmentSHA256
                    )
                    record = preparedRecord
                    recordID = preparedRecord.id
                    return preparedRecord
                } catch {
                    return nil
                }
            }

            guard automaticResumeWriteIsCurrent(
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision,
                    session: session,
                    store: store
                  ) else { throw CancellationError() }
            guard automaticResumeWritePermitAccountIDs.remove(account.id) != nil else { return .noAction }

            let authorizeExchangeCommit: @MainActor () -> Bool = {
                guard store.allowsAutomaticResumeDelivery(accountID: account.id, conversationID: conversationID) else {
                    return false
                }
                guard self.automaticResumeWriteIsCurrent(
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision,
                    session: session,
                    store: store
                ) else { return false }
                do {
                    if let promotionRecord, let promotionEvidence {
                        let promoted = try store.promoteResumeDeliveryToNativeDispatch(
                            recordID: promotionRecord.id,
                            evidence: promotionEvidence,
                            remoteResumeToken: binding.remoteResumeToken,
                            writeBaselineRemoteMID: writeBaselineRemoteMID
                        )
                        record = promoted
                        recordID = promoted.id
                    } else {
                        guard let committedRecord = prepareRecordAtFirstWriteCommit() else {
                            return false
                        }
                        let dispatching = try store.transitionResumeDelivery(
                            recordID: committedRecord.id,
                            to: .dispatching,
                            remoteResumeToken: binding.remoteResumeToken,
                            writeBaselineRemoteMID: writeBaselineRemoteMID
                        )
                        record = dispatching
                        recordID = dispatching.id
                    }
                    stage = .exchangeWrite
                    return true
                } catch {
                    return false
                }
            }

            switch dispatchExchangeKind {
            case .acceptNativeRequest:
                guard case .accept(let acceptPreflight) = exchangePreflight else {
                    throw ResumeDeliveryStoreError.invalidNativePromotion
                }
                statusByAccount[account.id] = "正在接受招聘方的附件简历请求"
                let result = try await resumeExchange.acceptAttachmentResume(
                    preflight: acceptPreflight,
                    resumeToken: binding.remoteResumeToken,
                    scene: nativeScene,
                    commitIsStillAuthorized: authorizeExchangeCommit
                )
                guard automaticResumeWriteIsCurrent(
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision,
                    session: session,
                    store: store
                ) else { throw CancellationError() }
                guard result.state == .serverAcceptedUnverified else {
                    throw BossResumeExchangeError.invalidResponse(
                        endpoint: "/wapi/zpchat/exchange/accept"
                    )
                }
                guard let record else { throw ResumeDeliveryStoreError.recordMissing }
                _ = try store.transitionResumeDelivery(
                    recordID: record.id,
                    to: .serverAcceptedUnverified,
                    remoteResumeToken: binding.remoteResumeToken
                )
                statusByAccount[account.id] = "BOSS 已接受发送，正在回读确认"
                let isConfirmed = try await verifyNativeResumeDelivery(
                    recordID: record.id,
                    route: route,
                    profileID: session.profileID,
                    account: account,
                    session: session,
                    store: store,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision
                )
                guard automaticResumeWriteIsCurrent(
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision,
                    session: session,
                    store: store
                ) else { throw CancellationError() }
                return .completed(
                    status: isConfirmed
                        ? "附件简历已回读确认"
                        : "BOSS 已接受发送，等待下一轮消息回读确认"
                )
            case .requestRecruiterConfirmation:
                guard case .request(let requestPreflight) = exchangePreflight else {
                    throw BossResumeExchangeError.invalidResponse(
                        endpoint: "/wapi/zpchat/exchange/test"
                    )
                }
                statusByAccount[account.id] = "正在发起附件简历确认请求"
                let result = try await resumeExchange.requestAttachmentResume(
                    preflight: requestPreflight,
                    resumeToken: binding.remoteResumeToken,
                    commitIsStillAuthorized: authorizeExchangeCommit
                )
                guard automaticResumeWriteIsCurrent(
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    operationGeneration: operationGeneration,
                    identityRevision: identityRevision,
                    session: session,
                    store: store
                ) else { throw CancellationError() }
                guard result.state == .requestCreatedAwaitingRecruiter else {
                    throw BossResumeExchangeError.invalidResponse(
                        endpoint: "/wapi/zpchat/exchange/request"
                    )
                }
                guard let record else { throw ResumeDeliveryStoreError.recordMissing }
                _ = try store.transitionResumeDelivery(
                    recordID: record.id,
                    to: .requestCreatedAwaitingRecruiter,
                    remoteResumeToken: binding.remoteResumeToken
                )
                statusByAccount[account.id] = "已发起附件简历请求，等待招聘方在 BOSS 确认"
                return .completed(status: "已发起附件简历请求，等待招聘方在 BOSS 确认")
            }
        } catch is CancellationError {
            if stage.isAttachmentWrite {
                recoverAttachmentPreparationRecord(recordID: recordID, store: store)
                let status = "附件上传或保存未完成，下一轮将安全重试"
                statusByAccount[account.id] = status
                return .completed(status: status)
            }
            guard stage.remoteWriteMayHaveStarted else { return .cancelled }
            let failureCode = ResumeDeliveryFailureCode.requestOutcomeUnknown
            if let recordID {
                sealResumeDelivery(
                    recordID: recordID,
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    failureCode: failureCode,
                    store: store
                )
            }
            guard failureCode == .requestOutcomeUnknown else { return .cancelled }
            let status = "简历发送结果不确定，已禁止自动重试"
            addResumeDeliveryFailureActivityIfCurrentIdentity(
                accountID: account.id,
                remoteIdentityID: remoteIdentityID,
                failureCode: failureCode,
                store: store
            )
            return .requiresAttention(status: status)
        } catch {
            let failureCode = resumeDeliveryFailureCode(error, stage: stage)
            if stage.remoteWriteMayHaveStarted, let recordID {
                sealResumeDelivery(
                    recordID: recordID,
                    accountID: account.id,
                    remoteIdentityID: remoteIdentityID,
                    failureCode: failureCode,
                    store: store
                )
            }
            let operationRemainsCurrent = operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            )
            if let exchangeError = error as? BossResumeExchangeError,
               case .APIError(let endpoint, let code, _) = exchangeError,
               BossServerFailurePolicy.requiresManualVerification(code),
               operationRemainsCurrent {
                if stage.isAttachmentWrite {
                    recoverAttachmentPreparationRecord(recordID: recordID, store: store)
                }
                stopAccountForManualVerification(
                    account: account,
                    code: code,
                    operation: endpoint,
                    message: "BOSS 附件与消息接口要求本人完成安全验证",
                    store: store
                )
                return .requiresAttention(
                    status: "BOSS 本次附件请求未通过（\(code)），未设置本地账号限制"
                )
            }
            if let exchangeError = error as? BossResumeExchangeError,
               case .APIError(_, let code, _) = exchangeError,
               code == 37,
               operationRemainsCurrent {
                if stage.isAttachmentWrite {
                    recoverAttachmentPreparationRecord(recordID: recordID, store: store)
                }
                await session.markAutomationCredentialStale()
                statusByAccount[account.id] = stage.remoteWriteMayHaveStarted
                    ? "网页令牌已过期；简历发送结果待人工核验"
                    : "网页令牌已过期，正在自动重新准备会话"
                return stage.remoteWriteMayHaveStarted
                    ? .requiresAttention(status: statusByAccount[account.id] ?? "简历发送结果待人工核验")
                    : .completed(status: statusByAccount[account.id] ?? "网页会话正在刷新")
            }
            if let exchangeError = error as? BossResumeExchangeError,
               case .unauthenticated = exchangeError,
               operationRemainsCurrent {
                let cleared = await session.markServerSessionExpired()
                guard operationIsCurrent(
                    accountID: account.id,
                    generation: operationGeneration,
                    store: store
                ), store.snapshot.accounts.first(where: { $0.id == account.id })?
                    .remoteProfile?.remoteID.nilIfBlank == remoteIdentityID else {
                    return .cancelled
                }
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
                let status = cleared
                    ? "登录已失效，等待重新扫码"
                    : "登录已失效，本地会话清理未完成"
                statusByAccount[account.id] = status
                return .authenticationExpired(status: status)
            }
            guard operationRemainsCurrent else { return .cancelled }
            if let cooldownSeconds = Self.safetyCooldownSeconds(for: error) {
                applySafetyCooldown(seconds: cooldownSeconds, reason: error.localizedDescription, store: store)
                return .requiresAttention(status: "BOSS 附件接口已触发风控冷却；不确定的发送不会重试")
            }
            if stage.isAttachmentWrite {
                recoverAttachmentPreparationRecord(recordID: recordID, store: store)
                let status = "附件上传或保存未完成，未发送给招聘方，下一轮将重试"
                statusByAccount[account.id] = status
                store.addActivity(
                    accountID: account.id,
                    level: .warning,
                    title: "BOSS 附件准备待重试",
                    detail: status
                )
                return .completed(status: status)
            }
            if stage == .preparation, failureCode == .cancelled {
                return .cancelled
            }
            let status = failureCode == .requestOutcomeUnknown
                ? "简历发送结果不确定，已禁止自动重试"
                : "附件简历本次未发送"
            statusByAccount[account.id] = status
            addResumeDeliveryFailureActivityIfCurrentIdentity(
                accountID: account.id,
                remoteIdentityID: remoteIdentityID,
                failureCode: failureCode,
                store: store
            )
            return .requiresAttention(status: status)
        }
    }

    private func recoverAttachmentPreparationRecord(
        recordID: String?,
        store: AppStore
    ) {
        guard let recordID,
              store.resumeDeliveryRecord(id: recordID)?.state == .preparingAttachment else {
            return
        }
        _ = try? store.transitionResumeDelivery(recordID: recordID, to: .queued)
    }

    private func sealResumeDelivery(
        recordID: String,
        accountID: UUID,
        remoteIdentityID: String,
        failureCode: ResumeDeliveryFailureCode,
        store: AppStore
    ) {
        guard let record = store.resumeDeliveryRecord(id: recordID),
              record.accountID == accountID,
              record.remoteIdentityID == remoteIdentityID,
              record.state == .queued ||
                record.state == .preparingAttachment ||
                record.state == .dispatching else {
            return
        }
        if failureCode == .cancelled, record.state != .dispatching {
            _ = try? store.transitionResumeDelivery(recordID: recordID, to: .cancelled)
        } else {
            let resolvedFailureCode = record.state == .dispatching && failureCode == .cancelled
                ? .requestOutcomeUnknown
                : failureCode
            _ = try? store.transitionResumeDelivery(
                recordID: recordID,
                to: .failed,
                failureCode: resolvedFailureCode
            )
        }
    }

    private func addResumeDeliveryFailureActivityIfCurrentIdentity(
        accountID: UUID,
        remoteIdentityID: String,
        failureCode: ResumeDeliveryFailureCode,
        store: AppStore
    ) {
        guard store.snapshot.accounts.contains(where: {
            $0.id == accountID &&
                $0.status == .active &&
                $0.remoteProfile?.remoteID.nilIfBlank == remoteIdentityID
        }) else { return }
        store.addActivity(
            accountID: accountID,
            level: .error,
            title: failureCode == .requestOutcomeUnknown
                ? "附件简历结果待人工核验"
                : "附件简历未发送",
            detail: resumeDeliveryFailureDetail(failureCode)
        )
    }

    private func automaticResumeWriteIsCurrent(
        accountID: UUID,
        remoteIdentityID: String,
        operationGeneration: UInt64,
        identityRevision: UInt64,
        session: BossAccountSessionController,
        store: AppStore
    ) -> Bool {
        operationIsCurrent(
            accountID: accountID,
            generation: operationGeneration,
            store: store,
            session: session,
            identityRevision: identityRevision
        ) &&
        session.phase.isAuthenticated &&
        session.automationReady &&
        session.profileBindingVerified &&
        Self.automaticResumeCommitSettingsAllow(
            isAutomaticMode: store.snapshot.automation.mode == .automatic,
            allowsExternalActions: store.snapshot.automation.allowsExternalActions,
            automaticallyMonitorsMessages: store.snapshot.automation.automaticallyMonitorMessages,
            automaticallySendsResume: store.snapshot.automation.automaticallySendResume
        ) &&
        store.snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.nilIfBlank == remoteIdentityID
    }

    private func verifyNativeResumeDelivery(
        recordID: String,
        route: BossHistoryRoute,
        profileID: UUID,
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        operationGeneration: UInt64,
        identityRevision: UInt64
    ) async throws -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    throw CancellationError()
                }
            }
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else { throw CancellationError() }
            do {
                let page = try await resumeExchange.history(
                    profileID: profileID,
                    query: BossResumeHistoryQuery(
                        bossID: route.bossID,
                        groupID: route.groupID,
                        maximumMessageID: "0",
                        count: 50,
                        page: 1,
                        source: route.source,
                        securityID: route.securityID,
                        gid: route.groupID
                    )
                )
                guard operationIsCurrent(
                    accountID: account.id,
                    generation: operationGeneration,
                    store: store,
                    session: session,
                    identityRevision: identityRevision
                ) else { throw CancellationError() }
                _ = store.upsertBossHistoryMessages(
                    messages: page.messages,
                    accountID: account.id,
                    conversationID: route.conversationID,
                    authoritativeCurrentUserID: page.currentUserID
                )
                if ((try? reconcileNativeResumeDeliveries(
                    accountID: account.id,
                    conversationID: route.conversationID,
                    store: store
                )) ?? 0) > 0 {
                    statusByAccount[account.id] = "附件简历已回读确认"
                    store.addActivity(
                        accountID: account.id,
                        level: .success,
                        title: "附件简历已回读确认",
                        detail: "BOSS 完整消息已确认原生索要简历卡片完成。"
                    )
                    return true
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BossResumeExchangeError {
                if Self.safetyCooldownSeconds(for: error) != nil { throw error }
                if case .unauthenticated = error { throw error }
                if case .APIError(_, let code, _) = error,
                   code == 37 || BossServerFailurePolicy.requiresManualVerification(code) {
                    throw error
                }
                break
            } catch {
                break
            }
        }
        if store.resumeDeliveryRecord(id: recordID)?.state == .serverAcceptedUnverified {
            statusByAccount[account.id] = "BOSS 已接受发送，等待下一轮消息回读确认"
        }
        return false
    }

    private func resumeDeliveryFailureCode(
        _ error: Error,
        stage: ResumeDispatchStage
    ) -> ResumeDeliveryFailureCode {
        if error is ResumeDeliveryFileError { return .attachmentPreparationFailed }
        if error is ResumeDeliveryStoreError {
            return stage.remoteWriteMayHaveStarted ? .requestOutcomeUnknown : .invalidResponse
        }
        guard let exchangeError = error as? BossResumeExchangeError else {
            return stage.remoteWriteMayHaveStarted ? .requestOutcomeUnknown : .unknown
        }
        switch exchangeError {
        case .authorizationChanged:
            return stage.remoteWriteMayHaveStarted ? .requestOutcomeUnknown : .cancelled
        case .unauthenticated:
            return .authenticationRequired
        case .invalidPDF, .PDFTooLarge, .fileReadFailed:
            return stage == .preparation ? .attachmentPreparationFailed : .attachmentUploadFailed
        case .restrictedAttachment:
            return .requestRejected
        case .serviceInvalidated:
            return stage.remoteWriteMayHaveStarted ? .requestOutcomeUnknown : .cancelled
        case .requestTimedOut(_, let writeMayHaveCommitted),
             .httpStatus(_, _, let writeMayHaveCommitted),
             .APIError(_, _, let writeMayHaveCommitted),
             .businessStatus(_, _, let writeMayHaveCommitted):
            if writeMayHaveCommitted { return .requestOutcomeUnknown }
            return stage.isAttachmentWrite ? .attachmentUploadFailed : .requestRejected
        case .invalidResponse(let endpoint):
            if stage.remoteWriteMayHaveStarted && resumeExchangeEndpointMayWrite(endpoint) {
                return .requestOutcomeUnknown
            }
            return stage.isAttachmentWrite ? .attachmentUploadFailed : .invalidResponse
        case .bridgeEvaluationFailed, .bridgeTransportFailed, .responseTooLarge:
            return stage.remoteWriteMayHaveStarted ? .requestOutcomeUnknown : .requestRejected
        case .invalidParameter, .endpointNotAllowed:
            return .invalidResponse
        case .navigationFailed, .navigationTimedOut:
            return stage.remoteWriteMayHaveStarted ? .requestOutcomeUnknown : .requestRejected
        case .conversationStoreUnavailable,
             .greetingConversationUnavailable,
             .greetingConversationMismatch,
             .greetingWebSocketUnavailable,
             .greetingDeliveryUnconfirmed:
            return .requestRejected
        }
    }

    private func resumeExchangeEndpointMayWrite(_ endpoint: String) -> Bool {
        endpoint == "/wapi/zpupload/resume/uploadFile.json" ||
            endpoint == "/wapi/zpgeek/resume/attachment/save.json" ||
            endpoint == "/wapi/zpchat/exchange/request" ||
            endpoint == "/wapi/zpchat/exchange/accept"
    }

    private func resumeDeliveryFailureDetail(_ code: ResumeDeliveryFailureCode) -> String {
        switch code {
        case .attachmentPreparationFailed: "本地附件准备失败；未向 BOSS 发送简历。"
        case .attachmentUploadFailed: "附件上传或保存未完成；未执行简历发送请求。"
        case .authenticationRequired: "BOSS 登录已失效；未继续发送。"
        case .requestRejected: "BOSS 预检或发送请求被拒绝；不会自动重试。"
        case .requestOutcomeUnknown: "写请求可能已被 BOSS 处理；为防止重复投递，必须人工核验。"
        case .invalidResponse: "BOSS 返回无法安全验证；未继续发送。"
        case .verificationFailed: "BOSS 已接受操作，但完整消息尚未确认结果。"
        case .cancelled: "账号操作已取消；不会自动重试。"
        case .unknown: "本次操作未完成；不会自动重试。"
        }
    }

    private func handleResumeExchangeReadError(
        _ error: BossResumeExchangeError,
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        operationGeneration: UInt64,
        identityRevision: UInt64
    ) async {
        let remoteIdentityID = store.snapshot.accounts.first(where: {
            $0.id == account.id && $0.status == .active
        })?.remoteProfile?.remoteID.nilIfBlank
        guard operationIsCurrent(
            accountID: account.id,
            generation: operationGeneration,
            store: store,
            session: session,
            identityRevision: identityRevision
        ) else { return }
        if let cooldownSeconds = Self.safetyCooldownSeconds(for: error) {
            applySafetyCooldown(seconds: cooldownSeconds, reason: error.localizedDescription, store: store)
            return
        }
        switch error {
        case .unauthenticated:
            let cleared = await session.markServerSessionExpired()
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store
            ), store.snapshot.accounts.first(where: { $0.id == account.id })?
                .remoteProfile?.remoteID.nilIfBlank == remoteIdentityID else { return }
            store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            statusByAccount[account.id] = cleared
                ? "登录已失效，等待重新扫码"
                : "登录已失效，本地会话清理未完成"
        case .APIError(_, let code, _) where code == 37:
            await session.markAutomationCredentialStale()
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store
            ), store.snapshot.accounts.first(where: { $0.id == account.id })?
                .remoteProfile?.remoteID.nilIfBlank == remoteIdentityID else { return }
            statusByAccount[account.id] = "网页令牌已过期，正在自动重新准备会话"
        case .APIError(let endpoint, let code, _)
            where BossServerFailurePolicy.requiresManualVerification(code):
            stopAccountForManualVerification(
                account: account,
                code: code,
                operation: endpoint,
                message: "BOSS 消息接口要求本人完成安全验证",
                store: store
            )
        default:
            statusByAccount[account.id] = "BOSS 消息本轮读取失败，稍后自动重试"
            store.addActivity(
                accountID: account.id,
                level: .warning,
                title: "BOSS 消息本轮未同步",
                detail: "本次读取未完成；没有触发本地冷却，也没有执行简历发送。"
            )
        }
    }

    @discardableResult
    func recheckManualVerification(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore
    ) async -> AccountOperationOutcome {
        guard store.snapshot.accounts.first(where: { $0.id == account.id })?
            .manualVerificationChallenge != nil else {
            return await synchronizeProfile(account: account, session: session, store: store)
        }
        guard await session.refreshCredentialFromWebKit() else {
            statusByAccount[account.id] = "官方页面会话尚未恢复，请完成本人验证后重试"
            return .unavailable
        }
        return await performProfileSynchronization(
            account: account,
            session: session,
            store: store,
            intent: .explicitManualVerificationRecheck
        )
    }

    @discardableResult
    func synchronizeProfile(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore
    ) async -> AccountOperationOutcome {
        await performProfileSynchronization(
            account: account,
            session: session,
            store: store,
            intent: .regular
        )
    }

    private func verifyPersistedProfileBinding(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore
    ) async -> AccountOperationOutcome {
        guard let expectedRemoteID = store.snapshot.accounts.first(where: {
            $0.id == account.id && $0.status == .active
        })?.remoteProfile?.remoteID.nilIfBlank else {
            return await synchronizeProfile(account: account, session: session, store: store)
        }
        guard connectorRequestsAllowed(accountID: account.id, store: store) else { return .unavailable }
        guard let operationGeneration = beginOperation(accountID: account.id, profileID: account.webProfileID) else { return .busy }
        defer { finishOperation(accountID: account.id, generation: operationGeneration) }
        do {
            let requestToken = api.requestToken(accountID: account.id)
            let credential = try session.credential()
            guard credential.isAutomationReady,
                  let identityRevision = session.currentIdentityRevision() else {
                throw BossAutomationError.incompleteWebCredential
            }
            statusByAccount[account.id] = "正在确认账号身份，随后显示首批岗位"
            let result = try await api.accountIdentity(
                accountID: account.id,
                profileID: account.webProfileID,
                credential: credential,
                requestToken: requestToken
            )
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision,
                requiringProfileBinding: false
            ) else { return .unavailable }
            guard await applyRefreshedCredential(
                result.refreshedCredential,
                account: account,
                session: session,
                store: store,
                identityRevision: identityRevision
            ) else { return .unavailable }
            guard result.value.remoteID.nilIfBlank == expectedRemoteID else {
                _ = await session.markServerSessionExpired()
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
                throw BossAccountBindingError.unexpectedIdentity
            }
            session.markProfileBindingVerified(identityRevision: identityRevision)
            guard session.isCurrentIdentityRevision(
                identityRevision,
                requiringProfileBinding: true
            ) else { return .unavailable }
            statusByAccount[account.id] = "账号身份已确认，正在获取首批岗位"
            return .performed
        } catch is CancellationError {
            return .unavailable
        } catch {
            await handle(
                error,
                account: account,
                session: session,
                store: store,
                operationGeneration: operationGeneration
            )
            return .unavailable
        }
    }

    private func performProfileSynchronization(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        intent: ProfileSynchronizationIntent
    ) async -> AccountOperationOutcome {
        guard store.snapshot.accounts.contains(where: { $0.id == account.id && $0.status == .active }) else { return .unavailable }
        if !intent.allowsManualVerificationChallenge {
            guard connectorRequestsAllowed(accountID: account.id, store: store) else { return .unavailable }
        }
        guard BossManualVerificationGate.allowsAuthoritativeProfileRead(
            connectorReadsEnabled: store.snapshot.automation.allowsConnectorReads,
            explicitRecheckRequested: intent == .explicitManualVerificationRecheck
        ) else { return .unavailable }
        guard let operationGeneration = beginOperation(accountID: account.id, profileID: account.webProfileID) else { return .busy }
        defer { finishOperation(accountID: account.id, generation: operationGeneration) }
        do {
            let requestToken = api.requestToken(accountID: account.id)
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                allowsManualVerificationChallenge: intent.allowsManualVerificationChallenge
            ) else { return .unavailable }
            let credential = try session.credential()
            guard credential.isAutomationReady else { throw BossAutomationError.incompleteWebCredential }
            guard let identityRevision = session.currentIdentityRevision() else { return .unavailable }
            statusByAccount[account.id] = "正在同步 BOSS 账号资料"
            let result = try await api.accountProfile(
                accountID: account.id,
                profileID: account.webProfileID,
                credential: credential,
                requestToken: requestToken
            )
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision,
                requiringProfileBinding: false,
                allowsManualVerificationChallenge: intent.allowsManualVerificationChallenge
            ) else { return .unavailable }
            guard await applyRefreshedCredential(
                result.refreshedCredential,
                account: account,
                session: session,
                store: store,
                identityRevision: identityRevision
            ) else { return .unavailable }
            do {
                let identityChanged = try store.applyBossProfile(result.value, accountID: account.id)
                if identityChanged {
                    lastSearchAtByAccount[account.id] = nil
                    lastMessageSyncAtByAccount[account.id] = nil
                }
            } catch let bindingError as BossAccountBindingError {
                _ = await session.markServerSessionExpired()
                store.report(bindingError)
                return .unavailable
            }
            session.markProfileBindingVerified(identityRevision: identityRevision)
            guard session.isCurrentIdentityRevision(identityRevision, requiringProfileBinding: true) else { return .unavailable }
            let currentChallenge = store.snapshot.accounts.first(where: { $0.id == account.id })?
                .manualVerificationChallenge
            if BossManualVerificationGate.shouldClear(
                challenge: currentChallenge,
                explicitRecheckRequested: intent == .explicitManualVerificationRecheck,
                authoritativeProfileReadSucceeded: true
            ) {
                store.clearBossManualVerificationChallenge(accountID: account.id)
                store.addActivity(
                    accountID: account.id,
                    level: .success,
                    title: "BOSS 本人验证已确认恢复",
                    detail: "同一 WebKit Profile 已成功回读账号资料；人工验证锁已解除，可重新启动自动任务。"
                )
            }
            statusByAccount[account.id] = "BOSS 账号资料已同步"
            store.addActivity(
                accountID: account.id,
                level: .success,
                title: "BOSS 账号资料已同步",
                detail: result.warnings.isEmpty
                    ? (result.value.name.isEmpty ? "已更新在线求职资料。" : "已识别账号：\(result.value.name)。")
                    : "已识别账号：\(result.value.name.nilIfBlank ?? "当前账号")。\(result.warnings.joined(separator: "；"))。岗位与消息读取将继续。"
            )
            return .performed
        } catch is CancellationError {
            return .unavailable
        } catch {
            await handle(
                error,
                account: account,
                session: session,
                store: store,
                operationGeneration: operationGeneration,
                allowsManualVerificationChallenge: intent.allowsManualVerificationChallenge
            )
            return .unavailable
        }
    }

    private func ensureProfileBinding(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore
    ) async -> Bool {
        guard session.phase.isAuthenticated, session.automationReady else {
            statusByAccount[account.id] = session.phase.isAuthenticated ? "接口会话正在准备" : "等待扫码登录"
            return false
        }
        if session.profileBindingVerified,
           store.snapshot.accounts.contains(where: {
               $0.id == account.id && $0.remoteProfile?.remoteID.nilIfBlank != nil
           }) {
            return true
        }
        return await synchronizeProfile(account: account, session: session, store: store) == .performed
    }

    private func sendNextQualifiedGreeting(
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore
    ) async -> AccountOperationOutcome {
        guard store.snapshot.automation.allowsExternalActions,
              store.snapshot.automation.automaticallySendGreetings else { return .unavailable }
        guard connectorRequestsAllowed(accountID: account.id, store: store) else { return .unavailable }
        if let automaticWritesAllowedAfter,
           automaticWritesAllowedAfter > Date() {
            statusByAccount[account.id] = "自动运行已启动；首轮只读，开聊最早于 \(automaticWritesAllowedAfter.formatted(date: .omitted, time: .shortened))"
            return .unavailable
        }
        guard await ensureProfileBinding(account: account, session: session, store: store),
              let identityRevision = session.currentIdentityRevision(requiringProfileBinding: true) else {
            return .unavailable
        }
        if let retryAt = dailyCommunicationRetryAt[account.id], retryAt > Date() {
            statusByAccount[account.id] = "今日沟通统计待核对，稍后重试；已有会话继续处理"
            return .unavailable
        }
        let completedToday = store.automaticGreetingCountToday(accountID: account.id)
        let dailyLimit = store.snapshot.automation.dailyGreetingLimit
        guard completedToday < dailyLimit else {
            statusByAccount[account.id] = "今日打招呼已达上限"
            return .unavailable
        }
        if let nextAllowedAt = store.nextAutomaticGreetingAllowedAt(
            accountID: account.id,
            intervalSeconds: store.snapshot.automation.greetingIntervalSeconds
        ), nextAllowedAt > Date() {
            statusByAccount[account.id] = "下一次开聊最早于 \(nextAllowedAt.formatted(date: .omitted, time: .shortened))"
            return .unavailable
        }
        let job = store.snapshot.jobs
            .filter {
                $0.accountID == account.id &&
                $0.stage == .recommended &&
                $0.hasAuthoritativeDescription &&
                $0.securityID?.isEmpty == false &&
                $0.remoteJobID?.isEmpty == false &&
                $0.listID?.isEmpty == false &&
                !store.hasAutomaticGreetingAttempt(
                    accountID: $0.accountID,
                    remoteJobID: $0.remoteJobID ?? ""
                ) &&
                JobMatchingPolicy.hardGateFailures(
                    job: $0,
                    preferences: store.snapshot.preferences
                ).isEmpty
            }
            .min { lhs, rhs in
                if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
                return lhs.id < rhs.id
            }
        guard let job,
              let securityID = job.securityID,
              let remoteJobID = job.remoteJobID,
              let listID = job.listID else { return .unavailable }
        let greetingText = store.snapshot.preferences.greetingTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !greetingText.isEmpty else { return .unavailable }
        guard let operationGeneration = beginOperation(accountID: account.id, profileID: account.webProfileID) else { return .busy }
        defer { finishOperation(accountID: account.id, generation: operationGeneration) }
        do {
            let requestToken = api.requestToken(accountID: account.id)
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ), session.phase.isAuthenticated,
               session.automationReady,
               session.profileBindingVerified,
               store.snapshot.accounts.first(where: { $0.id == account.id })?.remoteProfile?.remoteID.nilIfBlank != nil else {
                return .unavailable
            }
            var credential = try session.credential()
            guard credential.isAutomationReady else { throw BossAutomationError.incompleteWebCredential }
            do {
                credential = try await refreshDailyInteractions(
                    account: account, session: session, store: store,
                    generation: operationGeneration, identityRevision: identityRevision, credential: credential
                )
            } catch let error as BossAPIError {
                if case .invalidPayload = error {
                    store.addActivity(accountID: account.id, level: .warning,
                                      title: "今日沟通统计待核对", detail: error.localizedDescription)
                    return .unavailable
                }
                throw error
            }
            guard store.automaticGreetingCountToday(accountID: account.id) < dailyLimit,
                  !store.hasAutomaticGreetingAttempt(accountID: account.id, remoteJobID: remoteJobID) else {
                statusByAccount[account.id] = "手动与工具沟通已核对；本岗位已沟通或今日额度已用完"
                return .unavailable
            }
            try store.prepareAutomaticGreeting(jobID: job.id)
            statusByAccount[account.id] = "正在对 \(job.title) 发起开聊"
            let result = try await api.greet(
                accountID: account.id,
                profileID: account.webProfileID,
                credential: credential,
                requestToken: requestToken,
                securityID: securityID,
                jobID: remoteJobID,
                listID: listID
            )
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else {
                return .unavailable
            }
            credential = result.refreshedCredential
            guard await applyRefreshedCredential(
                credential,
                account: account,
                session: session,
                store: store,
                identityRevision: identityRevision
            ) else {
                return .unavailable
            }
            let receipt = try await resumeExchange.sendGreetingAndConfirm(
                profileID: account.webProfileID,
                expectedSecurityID: securityID,
                expectedJobID: remoteJobID,
                text: greetingText,
                commitIsStillAuthorized: { [weak self, weak store, weak session] in
                    guard let self, let store, let session else { return false }
                    return self.operationIsCurrent(
                        accountID: account.id,
                        generation: operationGeneration,
                        store: store,
                        session: session,
                        identityRevision: identityRevision
                    ) && store.snapshot.automation.automaticallySendGreetings
                },
                markWriteStarted: { [weak store] in
                    guard let store else { throw BossAutomationError.operationNotReady }
                    try store.markAutomaticGreetingWriteStarted(jobID: job.id)
                }
            )
            guard operationIsCurrent(
                accountID: account.id,
                generation: operationGeneration,
                store: store,
                session: session,
                identityRevision: identityRevision
            ) else {
                return .unavailable
            }
            store.recordAutomaticGreeting(
                jobID: job.id,
                confirmedMessageID: receipt.messageID,
                deliveredAt: receipt.deliveredAt
            )
            let confirmedCount = store.confirmedAutomaticGreetingCountToday(accountID: account.id)
            let attemptedCount = store.automaticGreetingCountToday(accountID: account.id)
            statusByAccount[account.id] = "工具确认开聊 \(confirmedCount) 个；手动与工具合计占用 \(attemptedCount)/\(dailyLimit)"
            return .performed
        } catch is CancellationError {
            return .unavailable
        } catch {
            if case .webTokenExpired? = error as? BossAPIError {
                do {
                    try store.releaseAutomaticGreetingReservationAfterDefinitiveRejection(
                        jobID: job.id
                    )
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "自动开聊将在会话恢复后重试",
                        detail: "\(job.title) · \(job.company)。BOSS 已明确拒绝本次请求，招聘方消息写入尚未开始；本次未消耗开聊额度。"
                    )
                } catch {
                    // 写入可能已提交或持久化失败时保留账本并停止重试，避免重复发送。
                }
            }
            await handle(
                error,
                account: account,
                session: session,
                store: store,
                operationGeneration: operationGeneration
            )
            return .unavailable
        }
    }

    private func applyRefreshedCredential(
        _ credential: BossCredential,
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        identityRevision: UInt64
    ) async -> Bool {
        switch await session.applyAuthoritativeCredential(
            credential,
            identityRevision: identityRevision
        ) {
        case .applied:
            return true
        case .expired:
            store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            statusByAccount[account.id] = "登录已失效，等待重新扫码"
            store.addActivity(
                accountID: account.id,
                level: .error,
                title: "BOSS 登录态已失效",
                detail: "BOSS 响应已撤销身份凭证，本账号已停止继续访问。"
            )
            return false
        case .failed:
            if case .failed(let message) = session.phase {
                statusByAccount[account.id] = "本地会话更新失败"
                store.addActivity(
                    accountID: account.id,
                    level: .error,
                    title: "BOSS 会话更新失败",
                    detail: message
                )
            }
            return false
        }
    }

    private func handle(
        _ error: Error,
        account: BossAccount,
        session: BossAccountSessionController,
        store: AppStore,
        operationGeneration: UInt64,
        allowsManualVerificationChallenge: Bool = false
    ) async {
        guard operationIsCurrent(
            accountID: account.id,
            generation: operationGeneration,
            store: store,
            allowsManualVerificationChallenge: allowsManualVerificationChallenge
        ) else { return }
        statusByAccount[account.id] = error.localizedDescription
        let apiError = error as? BossAPIError
        let automationError = error as? BossAutomationError
        if case .manualVerificationRequired(let operation, let code, let message)? = apiError {
            stopAccountForManualVerification(
                account: account,
                code: code,
                operation: operation.rawValue,
                message: message,
                store: store
            )
            return
        } else if case .authenticationRequired? = apiError {
            let localSessionCleared = await session.markServerSessionExpired()
            store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            statusByAccount[account.id] = localSessionCleared
                ? "登录已失效，等待重新扫码"
                : "登录已失效，本地凭证清理未完成"
        } else if case .webTokenExpired? = apiError {
            await session.markAutomationCredentialStale()
            statusByAccount[account.id] = "网页令牌已过期，正在自动重新准备会话"
            store.addActivity(
                accountID: account.id,
                level: .warning,
                title: "BOSS 网页会话正在刷新",
                detail: "岗位和消息同步令牌已过期，登录身份仍保留；系统将自动打开隐藏官方页面完成预热。"
            )
            return
        } else if case .incompleteWebCredential? = automationError {
            await session.markAutomationCredentialStale()
            statusByAccount[account.id] = "接口会话正在自动准备"
            return
        }
        if let cooldownSeconds = Self.safetyCooldownSeconds(for: error) {
            applySafetyCooldown(
                seconds: cooldownSeconds,
                reason: error.localizedDescription,
                store: store
            )
        }
        let title: String
        if case .authenticationRequired? = apiError {
            title = "BOSS 登录态已失效"
        } else {
            title = "BOSS 本次任务失败"
        }
        let isRecentDuplicate = store.snapshot.activity.prefix(20).contains { entry in
            entry.accountID == account.id &&
            entry.title == title &&
            entry.detail == error.localizedDescription &&
            Date().timeIntervalSince(entry.createdAt) < 60
        }
        if !isRecentDuplicate {
            store.addActivity(accountID: account.id, level: .error, title: title, detail: error.localizedDescription)
        }
    }

    static func safetyCooldownSeconds(for error: Error) -> TimeInterval? {
        if let exchangeError = error as? BossResumeExchangeError {
            switch exchangeError {
            case .httpStatus(_, 429, _), .httpStatus(_, 403, _), .APIError(_, 9, _):
                return 24 * 60 * 60
            case .APIError(_, let code, _) where BossServerFailurePolicy.requiresManualVerification(code):
                return 24 * 60 * 60
            default:
                break
            }
        }
        if let apiError = error as? BossAPIError,
           BossServerFailurePolicy.requiresSafetyCooldown(apiError) {
            return 24 * 60 * 60
        }
        return nil
    }

    private func applySafetyCooldown(
        seconds: TimeInterval,
        reason: String,
        store: AppStore
    ) {
        let proposedUntil = Date().addingTimeInterval(seconds)
        let currentUntil = store.snapshot.automation.safetyCooldownUntil
        let cooldownUntil = max(currentUntil ?? proposedUntil, proposedUntil)
        store.updateAutomation { $0.safetyCooldownUntil = cooldownUntil }
        stopWorker(using: store)
        store.flush()
        for account in Self.workerConfiguredAccounts(store.snapshot.accounts) {
            statusByAccount[account.id] = "检测到访问风险，后台已停止；\(cooldownUntil.formatted(date: .abbreviated, time: .shortened)) 后需手动检查并启动"
        }
        let duplicate = store.snapshot.activity.prefix(20).contains { entry in
            entry.title == "BOSS 访问已进入安全冷却" &&
                Date().timeIntervalSince(entry.createdAt) < 60
        }
        if !duplicate {
            store.addActivity(
                level: .warning,
                title: "BOSS 访问已进入安全冷却",
                detail: "BOSS 明确返回限流、拒绝访问或安全验证，已停止全部后台任务并取消排队请求。所有账号在 \(cooldownUntil.formatted(date: .abbreviated, time: .shortened)) 前不会继续请求；到期后需在官方页面确认账号正常，再手动启动。原因：\(reason)"
            )
        }
    }

    func invalidateOperations(accountID: UUID) {
        readyResumeBacklogAccountIDs.remove(accountID)
        operationGenerations[accountID, default: 0] &+= 1
        api.invalidateRequests(accountID: accountID)
        if let profileID = resumeExchangeProfileIDs.removeValue(forKey: accountID) {
            resumeExchange.forget(profileID: profileID)
        }
        backgroundAssessments[accountID]?.cancel()
        codexController?.cancelOperations(accountID: accountID)
        statusByAccount[accountID] = "账号操作已取消"
    }

    private func connectorRequestsAllowed(
        accountID: UUID,
        store: AppStore
    ) -> Bool {
        store.snapshot.automation.safetyCooldownUntil.map { $0 > Date() } != true &&
            store.snapshot.accounts.contains { $0.id == accountID && $0.status == .active }
    }

    private func stopAccountForManualVerification(
        account: BossAccount,
        code: Int,
        operation: String,
        message: String,
        store: AppStore
    ) {
        applySafetyCooldown(seconds: 24 * 60 * 60, reason: message, store: store)
        statusByAccount[account.id] = "BOSS 要求本人安全验证（\(code)），后台已停止，请在官方页面检查"
        let duplicate = store.snapshot.activity.prefix(20).contains { entry in
            entry.accountID == account.id &&
                entry.title == "BOSS 要求本人安全验证" &&
                entry.detail.contains("业务码 \(code)")
        }
        if !duplicate {
            store.addActivity(
                accountID: account.id,
                level: .warning,
                title: "BOSS 要求本人安全验证",
                detail: "\(operation)返回业务码 \(code)：\(message)。已进入 24 小时安全冷却，不会自动重试；请在 BOSS 官方页面完成验证并确认账号状态。"
            )
        }
    }

    /// 官方页面先跳转验证页时立即停止自动化，无需等待接口返回错误。
    func registerManualVerificationPage(
        account: BossAccount,
        url: URL?,
        store: AppStore
    ) {
        guard account.status == .active,
              account.manualVerificationChallenge == nil,
              let evidence = BossManualVerificationPagePolicy.evidence(from: url) else {
            return
        }
        stopAccountForManualVerification(
            account: account,
            code: evidence.code,
            operation: "BOSS 官方页面",
            message: "官方页面要求完成本人安全验证",
            store: store
        )
    }

    func cancelInvalidatedOperationsAndWait(accountID: UUID) async throws {
        statusByAccount[accountID] = "正在停止账号网络任务"
        await api.cancelActiveRequests(accountID: accountID)
        await codexController?.cancelOperationsAndWait(accountID: accountID)
        for _ in 0..<100 {
            if !runningAccountIDs.contains(accountID) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BossAutomationError.operationCancellationTimedOut
    }

    func beginOperation(accountID: UUID, profileID: UUID) -> UInt64? {
        guard !terminationRequested,
              !runningAccountIDs.contains(accountID) else { return nil }
        let generation = operationGenerations[accountID, default: 0]
        operationTokens[accountID] = generation
        resumeExchangeProfileIDs[accountID] = profileID
        runningAccountIDs.insert(accountID)
        return generation
    }

    func finishOperation(accountID: UUID, generation: UInt64) {
        guard operationTokens[accountID] == generation else { return }
        operationTokens[accountID] = nil
        runningAccountIDs.remove(accountID)
    }

    private func operationIsCurrent(
        accountID: UUID,
        generation: UInt64,
        store: AppStore,
        allowsManualVerificationChallenge: Bool = false
    ) -> Bool {
        !Task.isCancelled &&
        operationGenerations[accountID, default: 0] == generation &&
        store.snapshot.accounts.contains {
            $0.id == accountID && $0.status == .active
        }
    }

    private func operationIsCurrent(
        accountID: UUID,
        generation: UInt64,
        store: AppStore,
        session: BossAccountSessionController,
        identityRevision: UInt64,
        requiringProfileBinding: Bool = true,
        allowsManualVerificationChallenge: Bool = false
    ) -> Bool {
        operationIsCurrent(
            accountID: accountID,
            generation: generation,
            store: store,
            allowsManualVerificationChallenge: allowsManualVerificationChallenge
        ) &&
        session.isCurrentIdentityRevision(
            identityRevision,
            requiringProfileBinding: requiringProfileBinding
        )
    }

    private func cancelAllOperations() {
        for (accountID, task) in backgroundAssessments {
            task.cancel()
            codexController?.cancelOperations(accountID: accountID)
        }
        let resumeProfiles = Array(resumeExchangeProfileIDs.values)
        resumeExchangeProfileIDs.removeAll()
        for profileID in resumeProfiles {
            resumeExchange.forget(profileID: profileID)
        }
        for accountID in runningAccountIDs {
            operationGenerations[accountID, default: 0] &+= 1
            api.invalidateRequests(accountID: accountID)
            codexController?.cancelOperations(accountID: accountID)
            Task { await api.cancelActiveRequests(accountID: accountID) }
        }
    }

    private func conservativelyFinalizeInterruptedResumeDeliveries(using store: AppStore) {
        let activeIdentityByAccountID = store.snapshot.accounts.reduce(into: [UUID: String]()) {
            result, account in
            guard account.status == .active,
                  let remoteIdentityID = account.remoteProfile?.remoteID.nilIfBlank else {
                return
            }
            result[account.id] = remoteIdentityID
        }
        for record in store.snapshot.resumeDeliveryRecords where
            activeIdentityByAccountID[record.accountID] == record.remoteIdentityID {
            switch record.state {
            case .preparingAttachment:
                _ = try? store.transitionResumeDelivery(recordID: record.id, to: .queued)
            case .dispatching:
                _ = try? store.transitionResumeDelivery(
                    recordID: record.id,
                    to: .failed,
                    failureCode: .requestOutcomeUnknown
                )
            case .queued, .requestCreatedAwaitingRecruiter,
                 .serverAcceptedUnverified, .confirmed, .failed, .cancelled:
                break
            }
        }
    }

    private func waitForAvailableOperation(
        accountID: UUID,
        store: AppStore,
        waitingStatus: String,
        operation: () async -> AccountOperationOutcome
    ) async -> AccountOperationOutcome {
        while !Task.isCancelled,
              !terminationRequested,
              store.snapshot.accounts.contains(where: {
                  $0.id == accountID &&
                      $0.status == .active &&
                      $0.manualVerificationChallenge == nil
              }) {
            let outcome = await operation()
            guard outcome == .busy else { return outcome }
            statusByAccount[accountID] = waitingStatus
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return .unavailable
            }
        }
        return .unavailable
    }

    private func resolvedJobSearchTargets(store: AppStore) throws -> [BossJobSearchTarget] {
        let queries = searchQueries(store: store)
        guard !queries.isEmpty else { throw BossAutomationError.searchCriteriaRequired }
        let fallbackPlan = JobSearchPlanningPolicy.fallbackSearchPlan(
            resume: store.snapshot.resume,
            requirementText: store.snapshot.preferences.requirementText
        )
        let configuredCities = store.snapshot.preferences.plannedCities.isEmpty
            ? fallbackPlan.cities
            : store.snapshot.preferences.plannedCities
        let resolvedCities = try configuredCities.map { city -> (name: String, code: String) in
            guard let code = BossCityResolver.code(for: city) else {
                throw BossAutomationError.unsupportedCity(city)
            }
            return (city, code)
        }
        var seenTargets = Set<String>()
        let targets = queries.flatMap { query in
            resolvedCities.map { city in
                BossJobSearchTarget(query: query, city: city.name, cityCode: city.code)
            }
        }.filter { target in
            let key = [target.query.lowercased(), target.cityCode].joined(separator: "|")
            return !target.query.isEmpty && !target.cityCode.isEmpty && seenTargets.insert(key).inserted
        }
        // 遍历最多四个岗位方向与四个城市的全部组合，避免遗漏靠后的条件。
        let boundedTargets = Array(targets.prefix(16))
        guard !boundedTargets.isEmpty else { throw BossAutomationError.searchCriteriaRequired }
        return boundedTargets
    }

    private func jobSearchPlanFingerprint(
        accountID: UUID,
        targets: [BossJobSearchTarget],
        store: AppStore
    ) -> String? {
        guard let remoteIdentityID = store.snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.nilIfBlank else {
            return nil
        }
        return BossJobSearchPaginationPolicy.planFingerprint(
            remoteIdentityID: remoteIdentityID,
            resumeID: store.snapshot.resume.id,
            requirementText: store.snapshot.preferences.requirementText,
            targets: targets
        )
    }

    private func searchQueries(store: AppStore) -> [String] {
        let fallback = JobSearchPlanningPolicy.fallbackSearchPlan(
            resume: store.snapshot.resume,
            requirementText: store.snapshot.preferences.requirementText
        )
        let values = store.snapshot.preferences.plannedSearchQueries.isEmpty
            ? fallback.queries
            : store.snapshot.preferences.plannedSearchQueries
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func effectiveSearchIntervalMinutes(accountID: UUID, store: AppStore) -> Int {
        store.snapshot.automation.searchIntervalMinutes
    }

    private func refreshDailyInteractions(
        account: BossAccount, session: BossAccountSessionController, store: AppStore,
        generation: UInt64, identityRevision: UInt64, credential: BossCredential,
        resumeExchanges: Bool = false
    ) async throws -> BossCredential {
        guard let remoteIdentityID = store.snapshot.accounts.first(where: { $0.id == account.id })?.remoteProfile?.remoteID.nilIfBlank else {
            throw BossAutomationError.operationNotReady
        }
        let startedAt = Date()
        let retryAt = resumeExchanges ? dailyResumeExchangeRetryAt[account.id] : dailyCommunicationRetryAt[account.id]
        guard retryAt.map({ $0 > startedAt }) != true else {
            throw BossAutomationError.operationNotReady
        }
        let nextRetryAt = startedAt.addingTimeInterval(AutomationWorkerSchedulePolicy.pollingCeilingSeconds)
        if resumeExchanges { dailyResumeExchangeRetryAt[account.id] = nextRetryAt }
        else { dailyCommunicationRetryAt[account.id] = nextRetryAt }
        let startOfDay = Calendar.current.startOfDay(for: startedAt)
        // 回读重叠时间窗口，避免漏掉同秒记录和并发手动沟通。
        let lastSyncedAt = resumeExchanges ? store.dailyResumeExchangeLastSyncedAt(accountID: account.id)
            : store.dailyCommunicationLastSyncedAt(accountID: account.id)
        let needsRecipientBackfill = resumeExchanges && store.snapshot.dailyResumeExchangeRecords.contains {
            $0.identityFingerprint == AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: remoteIdentityID) &&
            $0.attemptedAt >= startOfDay && $0.recipientFingerprint == nil
        }
        let cutoff = needsRecipientBackfill ? startOfDay : max(startOfDay, (lastSyncedAt ?? startOfDay).addingTimeInterval(-120))
        var credential = credential
        var previousOldest: Date?
        var previousPageIDs: [String]?
        statusByAccount[account.id] = resumeExchanges ? "正在核对今日已交换记录" : "正在合并手动与工具的今日沟通"
        let requestToken = api.requestToken(accountID: account.id)
        for page in 1...100 {
            guard operationIsCurrent(accountID: account.id, generation: generation, store: store,
                                     session: session, identityRevision: identityRevision) else { throw CancellationError() }
            let result = try await api.dailyInteractions(
                accountID: account.id, profileID: account.webProfileID,
                credential: credential, requestToken: requestToken,
                page: page, remoteIdentityID: remoteIdentityID, resumeExchanges: resumeExchanges
            )
            guard operationIsCurrent(accountID: account.id, generation: generation, store: store,
                                     session: session, identityRevision: identityRevision),
                  Calendar.current.isDate(startedAt, inSameDayAs: Date()) else { throw CancellationError() }
            guard result.value.records.allSatisfy({ $0.attemptedAt <= Date().addingTimeInterval(60) }) else {
                throw BossAPIError.invalidPayload("互动时间异常，稍后重新核对统计。")
            }
            if let newest = result.value.records.first?.attemptedAt, let previousOldest,
               newest > previousOldest.addingTimeInterval(120) {
                throw BossAPIError.invalidPayload("互动分页在读取时发生变化，稍后重新核对统计。")
            }
            let pageIDs = result.value.records.map(\.id)
            guard previousPageIDs != pageIDs else {
                throw BossAPIError.invalidPayload("互动分页未前进，稍后重新核对统计。")
            }
            previousPageIDs = pageIDs
            credential = result.refreshedCredential
            guard await applyRefreshedCredential(credential, account: account, session: session,
                                                store: store, identityRevision: identityRevision) else { throw CancellationError() }
            if resumeExchanges { store.recordDailyResumeExchanges(result.value.records, now: Date()) }
            else { store.recordDailyCommunications(result.value.records, now: Date()) }
            previousOldest = result.value.records.last?.attemptedAt
            if !result.value.hasMore || previousOldest.map({ $0 < cutoff }) == true {
                if resumeExchanges {
                    store.completeDailyResumeExchangeSync(remoteIdentityID: remoteIdentityID, startedAt: startedAt)
                    dailyResumeExchangeRetryAt[account.id] = nil
                } else {
                    store.completeDailyCommunicationSync(remoteIdentityID: remoteIdentityID, startedAt: startedAt)
                    dailyCommunicationRetryAt[account.id] = nil
                }
                return credential
            }
        }
        throw BossAPIError.invalidPayload("今日互动列表尚未核对完整，稍后重新核对统计。")
    }

    private func usesCandidateSupply(store: AppStore) -> Bool {
        let settings = store.snapshot.automation
        return settings.mode == .automatic && settings.automaticallySearchJobs &&
            settings.automaticallyAssessJobs && settings.automaticallySendGreetings
    }

    private func candidateSupplyIsFull(accountID: UUID, store: AppStore) -> Bool {
        usesCandidateSupply(store: store) && !JobDetailBatchPolicy.needsCandidates(
            queuedCount: store.queuedAutomaticGreetingCandidateCount(accountID: accountID),
            usedDailyQuota: store.automaticGreetingCountToday(accountID: accountID),
            dailyLimit: store.snapshot.automation.dailyGreetingLimit
        )
    }

    func shouldYieldToGreeting(accountID: UUID, store: AppStore) -> Bool {
        guard usesCandidateSupply(store: store), store.snapshot.automation.workerEnabled,
              store.hasQueuedAutomaticGreetingCandidate(accountID: accountID),
              store.automaticGreetingCountToday(accountID: accountID) < store.snapshot.automation.dailyGreetingLimit
        else { return false }
        let now = Date()
        guard automaticWritesAllowedAfter.map({ $0 > now }) != true,
              dailyCommunicationRetryAt[accountID].map({ $0 > now }) != true else { return false }
        return store.nextAutomaticGreetingAllowedAt(
            accountID: accountID, intervalSeconds: store.snapshot.automation.greetingIntervalSeconds
        ).map { $0 <= now } ?? true
    }

    func searchIsDue(
        accountID: UUID,
        store: AppStore,
        forceInitialSearch: Bool = false
    ) -> Bool {
        guard !candidateSupplyIsFull(accountID: accountID, store: store) else { return false }
        if usesCandidateSupply(store: store), !forceInitialSearch {
            return AutomationWorkerSchedulePolicy.detailBacklogIsDue(
                lastAttemptAt: detailBacklogAttemptAtByAccount[accountID], now: Date(),
                intervalSeconds: AutomationWorkerSchedulePolicy.candidateReplenishmentIntervalSeconds
            )
        }
        let regularSearchIsDue = AutomationWorkerSchedulePolicy.jobSearchIsDue(
            lastCompletedAt: effectiveLastSearchAt(accountID: accountID, store: store),
            intervalMinutes: effectiveSearchIntervalMinutes(accountID: accountID, store: store),
            forceInitialSearch: forceInitialSearch,
            now: Date()
        )
        guard !regularSearchIsDue,
              hasPersistedDetailBacklog(accountID: accountID, store: store) else {
            return regularSearchIsDue
        }
        return AutomationWorkerSchedulePolicy.detailBacklogIsDue(
            lastAttemptAt: detailBacklogAttemptAtByAccount[accountID],
            now: Date()
        )
    }

    private func hasPersistedDetailBacklog(accountID: UUID, store: AppStore) -> Bool {
        store.snapshot.jobs.contains { job in
            job.accountID == accountID &&
                job.stage == .discovered &&
                !job.hasCachedDetail &&
                job.remoteJobID?.nilIfBlank != nil &&
                job.securityID?.nilIfBlank != nil &&
                job.listID?.nilIfBlank != nil &&
                !JobMatchingPolicy.hasDefinitiveListMismatch(job: job, preferences: store.snapshot.preferences) &&
                JobDetailBatchPolicy.canReadDetail(lastFailureAt: detailReadFailedAt[job.id])
        }
    }

    private func effectiveLastSearchAt(accountID: UUID, store: AppStore) -> Date? {
        let persistedLastSearchAt: Date? = if let targets = try? resolvedJobSearchTargets(store: store),
                                             let fingerprint = jobSearchPlanFingerprint(
                                                accountID: accountID,
                                                targets: targets,
                                                store: store
                                             ) {
            store.snapshot.automation.lastCompletedJobSearchAt(
                accountID: accountID,
                planFingerprint: fingerprint
            )
        } else {
            nil
        }
        return [lastSearchAtByAccount[accountID], persistedLastSearchAt]
            .compactMap { $0 }
            .max()
    }

    private func effectiveMessageIntervalMinutes(accountID: UUID, store: AppStore) -> Int {
        let remoteIdentityID = store.snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.nilIfBlank
        let hasUnresolvedResumeDelivery = if let remoteIdentityID {
            store.snapshot.resumeDeliveryRecords.contains(where: {
               $0.accountID == accountID &&
                   $0.remoteIdentityID == remoteIdentityID &&
                   ($0.state == .queued ||
                    $0.state == .preparingAttachment ||
                    $0.state == .dispatching ||
                    $0.state == .requestCreatedAwaitingRecruiter ||
                    $0.state == .serverAcceptedUnverified)
            })
        } else {
            false
        }
        return AutomationWorkerSchedulePolicy.messageSyncIntervalMinutes(
            hasUnresolvedResumeDelivery: hasUnresolvedResumeDelivery,
            hasReadyResumeDelivery: store.snapshot.automation.automaticallySendResume &&
                readyResumeBacklogAccountIDs.contains(accountID),
            intervalMinutes: store.snapshot.automation.monitorIntervalMinutes
        )
    }

    private func messageSyncIsDue(accountID: UUID, store: AppStore) -> Bool {
        guard let lastCompletedAt = lastMessageSyncAtByAccount[accountID] else { return true }
        return Date().timeIntervalSince(lastCompletedAt) >=
            TimeInterval(effectiveMessageIntervalMinutes(accountID: accountID, store: store) * 60)
    }

    private func nextWorkerDelayNanoseconds(
        store: AppStore,
        sessions: BossSessionCoordinator,
        now: Date = Date()
    ) -> UInt64 {
        if let cooldownUntil = store.snapshot.automation.safetyCooldownUntil, cooldownUntil > now {
            return UInt64(AutomationWorkerSchedulePolicy.boundedSleepSeconds(
                [cooldownUntil.timeIntervalSince(now)]
            ) * 1_000_000_000)
        }
        var candidateSeconds: [TimeInterval] = []
        var hasQueuedGreetingCandidate = false
        let activeAccounts = Self.workerScheduleEligibleAccounts(store.snapshot.accounts)
        if store.snapshot.automation.automaticallyMonitorMessages {
            let messageCandidates = activeAccounts.compactMap { account -> TimeInterval? in
                guard let session = sessions.existingSession(for: account.id) else { return nil }
                if session.phase.isAuthenticated, !session.automationReady { return 2 }
                guard session.automationReady else { return nil }
                return AutomationWorkerSchedulePolicy.secondsUntilDue(
                    lastCompletedAt: lastMessageSyncAtByAccount[account.id],
                    intervalMinutes: effectiveMessageIntervalMinutes(accountID: account.id, store: store),
                    now: now
                )
            }
            candidateSeconds.append(contentsOf: messageCandidates)
        }
        if store.snapshot.automation.automaticallySearchJobs {
            let searchCandidates = activeAccounts.compactMap { account -> TimeInterval? in
                guard !candidateSupplyIsFull(accountID: account.id, store: store) else { return nil }
                guard let session = sessions.existingSession(for: account.id) else { return nil }
                if session.phase.isAuthenticated, !session.automationReady { return 2 }
                guard session.automationReady else { return nil }
                if usesCandidateSupply(store: store) {
                    return AutomationWorkerSchedulePolicy.secondsUntilDetailBacklogDue(
                        lastAttemptAt: detailBacklogAttemptAtByAccount[account.id], now: now,
                        intervalSeconds: AutomationWorkerSchedulePolicy.candidateReplenishmentIntervalSeconds
                    )
                }
                return AutomationWorkerSchedulePolicy.secondsUntilDue(
                    lastCompletedAt: effectiveLastSearchAt(accountID: account.id, store: store),
                    intervalMinutes: effectiveSearchIntervalMinutes(accountID: account.id, store: store),
                    now: now
                )
            }
            candidateSeconds.append(contentsOf: searchCandidates)
            let backlogCandidates = activeAccounts.compactMap { account -> TimeInterval? in
                guard !usesCandidateSupply(store: store),
                      hasPersistedDetailBacklog(accountID: account.id, store: store),
                      sessions.existingSession(for: account.id)?.automationReady == true else {
                    return nil
                }
                return AutomationWorkerSchedulePolicy.secondsUntilDetailBacklogDue(
                    lastAttemptAt: detailBacklogAttemptAtByAccount[account.id],
                    now: now
                )
            }
            candidateSeconds.append(contentsOf: backlogCandidates)
        }
        if store.snapshot.automation.allowsExternalActions,
           store.snapshot.automation.automaticallySendGreetings {
            for account in activeAccounts where store.hasQueuedAutomaticGreetingCandidate(accountID: account.id) {
                if let retryAt = dailyCommunicationRetryAt[account.id], retryAt > now {
                    candidateSeconds.append(retryAt.timeIntervalSince(now))
                    continue
                }
                if store.automaticGreetingCountToday(accountID: account.id, now: now) >=
                    store.snapshot.automation.dailyGreetingLimit {
                    if let nextDay = Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: Calendar.current.startOfDay(for: now)
                    ) {
                        candidateSeconds.append(max(
                            AutomationWorkerSchedulePolicy.retryFloorSeconds,
                            nextDay.timeIntervalSince(now)
                        ))
                    }
                    continue
                }
                let nextAllowedAt = store.nextAutomaticGreetingAllowedAt(
                    accountID: account.id,
                    intervalSeconds: store.snapshot.automation.greetingIntervalSeconds
                ) ?? now
                let effectiveNextAllowedAt = max(nextAllowedAt, automaticWritesAllowedAfter ?? now)
                hasQueuedGreetingCandidate = true
                candidateSeconds.append(max(0, effectiveNextAllowedAt.timeIntervalSince(now)))
            }
        }
        // 至少每分钟重新检查调度，及时响应间隔调整、会话就绪和新增候选。
        let minimumSeconds = hasQueuedGreetingCandidate
            ? AutomationWorkerSchedulePolicy.responsiveWakeFloorSeconds
            : AutomationWorkerSchedulePolicy.retryFloorSeconds
        let seconds = AutomationWorkerSchedulePolicy.boundedSleepSeconds(
            candidateSeconds,
            minimumSeconds: minimumSeconds
        )
        return UInt64(seconds * 1_000_000_000)
    }

    static func workerScheduleEligibleAccounts(_ accounts: [BossAccount]) -> [BossAccount] {
        accounts.filter(BossManualVerificationGate.allowsAutomaticWork)
    }

    static func workerConfiguredAccounts(_ accounts: [BossAccount]) -> [BossAccount] {
        accounts.filter { $0.status == .active }
    }

    private func profileSyncIsDue(accountID: UUID, store: AppStore) -> Bool {
        guard let syncedAt = store.snapshot.accounts.first(where: { $0.id == accountID })?.remoteProfile?.syncedAt else {
            return true
        }
        return Date().timeIntervalSince(syncedAt) >= 6 * 60 * 60
    }

}

enum BossAutomationError: LocalizedError {
    case automaticModeRequired
    case resumeRequired
    case searchCriteriaRequired
    case incompleteWebCredential
    case noAutomaticTaskEnabled
    case automationCredentialRequired
    case connectorReadsDisabled
    case operationNotReady
    case operationCancellationTimedOut
    case unsupportedCity(String)

    var errorDescription: String? {
        switch self {
        case .automaticModeRequired: "请先在设置中把工作方式切换为“自动运行”。"
        case .resumeRequired: "请先在“求职偏好”中添加附件简历。"
        case .searchCriteriaRequired: "请先在“求职偏好”中写下自然语言求职要求。"
        case .incompleteWebCredential: "BOSS 账号已登录，但数据同步会话仍在自动准备，请稍后重试。"
        case .noAutomaticTaskEnabled: "请至少开启自动检索岗位或持续同步沟通列表。"
        case .automationCredentialRequired: "没有已恢复且数据同步会话就绪的 BOSS 账号，请先完成扫码并等待账号管理页准备完成。"
        case .connectorReadsDisabled: "当前是仅提醒模式，不会访问 BOSS；请切换到辅助模式或自动运行。"
        case .operationNotReady: "该岗位当前不能执行自动打招呼，操作已停止。"
        case .operationCancellationTimedOut: "该账号仍有网络任务未能及时停止，请稍后重新执行删除。"
        case .unsupportedCity(let city): "暂时无法确认“\(city)”对应的 BOSS 城市编码，本次检索已停止，避免误搜为全国。请改用常见城市名或 BOSS 数字城市编码。"
        }
    }
}

enum BossAccountBindingError: LocalizedError {
    case accountMissing
    case duplicateIdentity(String)
    case remoteIdentityMissing
    case unexpectedIdentity

    var errorDescription: String? {
        switch self {
        case .accountMissing:
            "本地账号已不存在，本次 BOSS 资料同步已丢弃。"
        case .duplicateIdentity(let existingAccount):
            "当前 BOSS 身份已绑定到“\(existingAccount)”。为避免多账号重复操作，本次登录已退出。"
        case .remoteIdentityMissing:
            "BOSS 本次未返回稳定账号标识，无法安全绑定本地账号；会话已退出以避免混合数据。"
        case .unexpectedIdentity:
            "当前网页会话与本地绑定的 BOSS 账号不一致；会话已退出，未继续检索或外发。"
        }
    }
}

private extension BossRemoteJob {
    init(listing: JobListing) {
        self.init(
            remoteJobID: listing.remoteJobID ?? "",
            securityID: listing.securityID ?? "",
            listID: listing.listID ?? "",
            title: listing.title,
            company: listing.company,
            location: listing.location,
            salary: listing.salary,
            experience: listing.experience,
            education: listing.education,
            description: listing.description,
            recruiterName: listing.recruiterName ?? "",
            url: listing.url,
            recruiterTitle: listing.recruiterTitle ?? "",
            industry: listing.industry ?? "",
            companySize: listing.companySize ?? "",
            financingStage: listing.financingStage ?? "",
            tags: listing.tags ?? [],
            benefits: listing.benefits ?? []
        )
    }

    func merging(_ detail: BossRemoteJob) -> BossRemoteJob {
        BossRemoteJob(
            remoteJobID: detail.remoteJobID.nilIfBlank ?? remoteJobID,
            securityID: detail.securityID.nilIfBlank ?? securityID,
            listID: detail.listID.nilIfBlank ?? listID,
            title: detail.title.nilIfBlank ?? title,
            company: detail.company.nilIfBlank ?? company,
            location: detail.location.nilIfBlank ?? location,
            salary: detail.salary.nilIfBlank ?? salary,
            experience: detail.experience.nilIfBlank ?? experience,
            education: detail.education.nilIfBlank ?? education,
            description: detail.description.nilIfBlank ?? description,
            recruiterName: detail.recruiterName.nilIfBlank ?? recruiterName,
            url: detail.url.nilIfBlank ?? url,
            recruiterTitle: detail.recruiterTitle.nilIfBlank ?? recruiterTitle,
            industry: detail.industry.nilIfBlank ?? industry,
            companySize: detail.companySize.nilIfBlank ?? companySize,
            financingStage: detail.financingStage.nilIfBlank ?? financingStage,
            tags: detail.tags.isEmpty ? tags : detail.tags,
            benefits: detail.benefits.isEmpty ? benefits : detail.benefits
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
