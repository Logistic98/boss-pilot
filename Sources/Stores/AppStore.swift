import Combine
import CryptoKit
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var snapshot: AppSnapshot {
        didSet {
            if oldValue.conversations != snapshot.conversations || oldValue.resumeDeliveryRecords != snapshot.resumeDeliveryRecords {
                resumeExchangeConversations = nil
                resumeExchangeJobs.removeAll(keepingCapacity: true)
            }
            greetingAttemptIDs = nil
            if oldValue.conversations != snapshot.conversations || oldValue.pendingActions != snapshot.pendingActions ||
                oldValue.resumeDeliveryRecords != snapshot.resumeDeliveryRecords { conversationRowsCache = nil }
            if oldValue.jobs != snapshot.jobs { sortedJobsCache = nil }
        }
    }
    @Published var selectedAccountID: UUID?
    @Published var accountFilterIDs: Set<UUID>? = nil

    var filteredAccounts: [BossAccount] {
        snapshot.accounts.filter { $0.status != .deleting && (accountFilterIDs?.contains($0.id) ?? true) }
    }

    var statisticsAccounts: [BossAccount] {
        filteredAccounts.filter { $0.status == .active && $0.loginStatus == .loggedIn }
    }

    func includesAccount(_ id: UUID) -> Bool {
        snapshot.accounts.contains { $0.id == id && $0.status != .deleting } && (accountFilterIDs?.contains(id) ?? true)
    }

    func toggleAccountFilter(_ id: UUID) {
        var ids = accountFilterIDs ?? Set(filteredAccounts.map(\.id))
        if !ids.insert(id).inserted { ids.remove(id) }
        accountFilterIDs = ids
    }
    @Published var selectedJobID: String?
    @Published var selectedConversationID: String?
    @Published var lastError: String?
    @Published var isEditingRequirements = false
    @Published var requirementsDraft: JobRequirementsDraft? {
        didSet {
            if hasUnsavedRequirementsChanges { isEditingRequirements = true }
        }
    }
    @Published private(set) var isSavingRequirements = false
    private var savedRequirementsDraft: JobRequirementsDraft?
    @Published var isShowingRequirementsPrompt = false

    var hasUnsavedRequirementsChanges: Bool {
        requirementsDraft != nil && requirementsDraft != savedRequirementsDraft
    }
    @Published private(set) var isLoaded = false
    @Published private(set) var persistenceBlocked = false

    private let persistence: JSONStatePersistence
    var localStateURL: URL { persistence.fileURL }
    private var saveTask: Task<Void, Never>?
    private var greetingAttemptIDs: Set<String>?
    private var conversationRowsCache: [(conversation: Conversation, state: ConversationWorkState)]?
    private var sortedJobsCache: [JobListing]?

    var conversationDisplayRows: [(conversation: Conversation, state: ConversationWorkState)] {
        if let cached = conversationRowsCache { return cached }
        let rows = ConversationPolicy.displayOrder(snapshot.conversations, actions: snapshot.pendingActions,
                                                   deliveryRecords: snapshot.resumeDeliveryRecords)
        conversationRowsCache = rows
        return rows
    }

    var jobsInDisplayOrder: [JobListing] {
        if let cached = sortedJobsCache { return cached }
        let jobs = snapshot.jobs.sorted {
            if ($0.assessment?.score ?? -1) != ($1.assessment?.score ?? -1) {
                return ($0.assessment?.score ?? -1) > ($1.assessment?.score ?? -1)
            }
            return $0.capturedAt > $1.capturedAt
        }
        sortedJobsCache = jobs
        return jobs
    }
    private var resumeExchangeJobs: [String: (job: JobListing, exchanged: Bool, sentAt: Date?)] = [:]
    private var resumeExchangeConversations: (
        securityIDs: [UUID: Set<String>],
        byCompany: [UUID: [String: [(conversation: Conversation, sentAt: Date?)]]],
        datesBySecurityID: [UUID: [String: Date]]
    )?

    init(persistence: JSONStatePersistence = .live()) {
        self.persistence = persistence
        self.snapshot = AppSnapshot()
    }

    deinit {
        saveTask?.cancel()
    }

    func load() {
        guard !isLoaded else { return }
        do {
            snapshot = try persistence.load()
            let didMigrateRemoteOnlyState = migrateRemoteOnlyState()
            if didMigrateRemoteOnlyState {
                try persistence.save(snapshot)
            }
            selectedAccountID = snapshot.accounts.first(where: { $0.status == .active })?.id ?? snapshot.accounts.first?.id
            selectedJobID = snapshot.jobs.first { selectedAccountID == nil || $0.accountID == selectedAccountID }?.id
            selectedConversationID = snapshot.conversations.first { selectedAccountID == nil || $0.accountID == selectedAccountID }?.id
        } catch {
            persistenceBlocked = true
            lastError = "读取本地数据失败：\(error.localizedDescription)。为保护原文件，本次运行已禁止任何状态写入。"
        }
        isLoaded = true
    }

    func addAccount(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let account = BossAccount(displayName: name)
        snapshot.accounts.append(account)
        selectedAccountID = account.id
        addActivity(accountID: account.id, level: .info, title: "已添加 BOSS 账号", detail: "请在账号管理页使用 BOSS 直聘 App 扫码登录。")
        scheduleSave()
    }

    @discardableResult
    func addBossAccount() -> UUID {
        var sequence = snapshot.accounts.count + 1
        var name = "BOSS 账号 \(sequence)"
        let existingNames = Set(snapshot.accounts.map(\.displayName))
        while existingNames.contains(name) {
            sequence += 1
            name = "BOSS 账号 \(sequence)"
        }
        addAccount(named: name)
        return selectedAccountID ?? snapshot.accounts.last!.id
    }

    func renameAccount(id: UUID, name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = snapshot.accounts.firstIndex(where: { $0.id == id && $0.status != .deleting }) else { return }
        snapshot.accounts[index].customName = name
        scheduleSave()
    }

    func synchronizeBossLoginStatus(accountID: UUID, loggedIn: Bool) {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let nextStatus: BossLoginStatus = loggedIn ? .loggedIn : .loggedOut
        guard snapshot.accounts[index].loginStatus != nextStatus else { return }
        snapshot.accounts[index].loginStatus = nextStatus
        if loggedIn, snapshot.accounts[index].lastLoginAt == nil {
            snapshot.accounts[index].lastLoginAt = Date()
        }
        scheduleSave()
    }

    func clearBossManualVerificationChallenge(accountID: UUID) {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == accountID }),
              snapshot.accounts[index].manualVerificationChallenge != nil else { return }
        snapshot.accounts[index].manualVerificationChallenge = nil
        scheduleSave()
    }

    /// 先持久化退出意图再清理会话，避免清理中崩溃后自动恢复登录。
    func beginBossSignOut(accountID: UUID) throws {
        guard !persistenceBlocked,
              let index = snapshot.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw BossAutomationError.operationNotReady
        }
        let previousStatus = snapshot.accounts[index].loginStatus
        snapshot.accounts[index].loginStatus = .loggedOut
        saveTask?.cancel()
        saveTask = nil
        do {
            try persistence.save(snapshot)
        } catch {
            snapshot.accounts[index].loginStatus = previousStatus
            throw error
        }
    }

    func removeAccount(id: UUID) throws {
        guard !persistenceBlocked,
              let accountToRemove = snapshot.accounts.first(where: { $0.id == id }) else {
            throw BossAutomationError.operationNotReady
        }
        let removedRemoteIdentityID = accountToRemove.remoteProfile?.remoteID.appStoreNonempty
        let previousSnapshot = snapshot
        let previousSelectedAccountID = selectedAccountID
        let previousSelectedJobID = selectedJobID
        let previousSelectedConversationID = selectedConversationID
        snapshot.accounts.removeAll { $0.id == id }
        normalizeAutomaticGreetingAttemptOwners()
        snapshot.jobs.removeAll { $0.accountID == id }
        snapshot.conversations.removeAll { $0.accountID == id }
        snapshot.pendingActions.removeAll { $0.accountID == id }
        snapshot.activity.removeAll { $0.accountID == id }
        snapshot.remoteResumeBindings.removeAll {
            $0.accountID == id ||
                (removedRemoteIdentityID != nil && $0.remoteIdentityID == removedRemoteIdentityID)
        }
        snapshot.resumeDeliveryRecords.removeAll {
            $0.accountID == id ||
                (removedRemoteIdentityID != nil && $0.remoteIdentityID == removedRemoteIdentityID)
        }
        snapshot.historyRouteRotationStates.removeAll {
            $0.accountID == id ||
                (removedRemoteIdentityID != nil && $0.remoteIdentityID == removedRemoteIdentityID)
        }
        snapshot.historyConversationSyncStates.removeAll {
            $0.accountID == id ||
                (removedRemoteIdentityID != nil && $0.remoteIdentityID == removedRemoteIdentityID)
        }
        if selectedAccountID == id { selectedAccountID = snapshot.accounts.first?.id }
        selectedJobID = snapshot.jobs.first { selectedAccountID == nil || $0.accountID == selectedAccountID }?.id
        selectedConversationID = snapshot.conversations.first { selectedAccountID == nil || $0.accountID == selectedAccountID }?.id
        saveTask?.cancel()
        saveTask = nil
        do {
            try persistence.save(snapshot)
        } catch {
            snapshot = previousSnapshot
            selectedAccountID = previousSelectedAccountID
            selectedJobID = previousSelectedJobID
            selectedConversationID = previousSelectedConversationID
            throw error
        }
    }

    func beginAccountDeletion(id: UUID) throws {
        guard !persistenceBlocked,
              let index = snapshot.accounts.firstIndex(where: { $0.id == id }) else {
            throw BossAutomationError.operationNotReady
        }
        let previousStatus = snapshot.accounts[index].status
        snapshot.accounts[index].status = .deleting
        saveTask?.cancel()
        saveTask = nil
        do {
            try persistence.save(snapshot)
        } catch {
            snapshot.accounts[index].status = previousStatus
            throw error
        }
    }

    func updateResume(_ transform: (inout ResumeProfile) -> Void) {
        var updated = snapshot
        let previous = updated.resume
        transform(&updated.resume)
        if updated.resume != previous {
            invalidateMatchingResults(in: &updated)
            snapshot = updated
        }
        scheduleSave()
    }

    func importResume(_ result: ResumeImportResult) {
        var updated = snapshot
        let previous = updated.resume
        // 每次导入创建新的简历版本，防止同路径、同大小的替换文件沿用在途任务。
        updated.resume.id = UUID()
        updated.resume.name = URL(fileURLWithPath: result.fileName).deletingPathExtension().lastPathComponent
        updated.resume.sourceFileName = result.fileName
        updated.resume.attachmentPath = result.attachmentPath
        updated.resume.attachmentSize = result.attachmentSize
        updated.resume.importedAt = Date()
        updated.resume.text = result.text
        updated.resume.skills = result.inferredSkills
        updated.resume.targetRoles = []
        updated.resume.yearsOfExperience = result.inferredYearsOfExperience
        updated.resume.profileSummary = ""
        updated.resume.suggestedSearchQueries = []
        updated.resume.suggestedCities = []
        updated.resume.profileGeneratedAt = nil
        updated.resume.profileProvider = ""
        updated.preferences.plannedSearchQueries = []
        updated.preferences.plannedCities = []
        updated.preferences.planGeneratedAt = nil
        updated.preferences.planProvider = ""
        if updated.resume != previous {
            invalidateMatchingResults(in: &updated)
        }
        snapshot = updated
        let skillDetail = result.inferredSkills.isEmpty ? "未识别到明确技术关键词" : "自动识别 \(result.inferredSkills.count) 项技能"
        addActivity(level: .success, title: "简历附件已保存", detail: "已从 \(result.fileName) 提取 \(result.text.count) 个字符，\(skillDetail)。")
        scheduleSave()
    }

    func applyResumeIntelligence(_ intelligence: ResumeIntelligence, expectedResumeID: UUID) {
        guard snapshot.resume.id == expectedResumeID, snapshot.resume.hasStoredAttachment else { return }
        var updated = snapshot
        updated.resume.profileSummary = intelligence.profileSummary
        updated.resume.suggestedSearchQueries = intelligence.searchQueries
        updated.resume.suggestedCities = intelligence.cities
        updated.resume.profileGeneratedAt = Date()
        updated.resume.profileProvider = intelligence.provider
        updated.preferences.plannedSearchQueries = []
        updated.preferences.plannedCities = []
        updated.preferences.planGeneratedAt = nil
        updated.preferences.planProvider = ""
        invalidateMatchingResults(in: &updated)
        snapshot = updated
        scheduleSave()
    }

    func applySearchPlan(_ plan: JobSearchPlan, requirementText: String, resumeID: UUID) {
        guard snapshot.resume.id == resumeID,
              snapshot.preferences.requirementText == requirementText else { return }
        var updated = snapshot
        let normalizedPlan = JobSearchPlanningPolicy.normalizedSearchPlan(
            queries: plan.queries,
            requirementText: requirementText,
            provider: plan.provider
        )
        updated.preferences.plannedSearchQueries = normalizedPlan.queries
        updated.preferences.plannedCities = normalizedPlan.cities
        updated.preferences.planGeneratedAt = Date()
        updated.preferences.planProvider = normalizedPlan.provider
        invalidateMatchingResults(in: &updated)
        snapshot = updated
        scheduleSave()
    }

    /// 移除旧手工记录和纯文本简历，避免升级后意外恢复自动外发。
    private func migrateRemoteOnlyState() -> Bool {
        var changed = false
        let originalSchemaVersion = snapshot.schemaVersion
        if originalSchemaVersion < 9, !snapshot.resumeDeliveryRecords.isEmpty {
            // 清理旧归属数据前先保留脱敏防重账本。
            snapshot.resumeConsentSafetyRecords.append(contentsOf:
                snapshot.resumeDeliveryRecords.map(ResumeConsentSafetyRecord.init(record:))
            )
            changed = true
        }
        if snapshot.schemaVersion < 2 {
            snapshot.schemaVersion = 2
            changed = true
        }

        for index in snapshot.accounts.indices {
            if !snapshot.accounts[index].browserProfileHint.isEmpty {
                snapshot.accounts[index].browserProfileHint = ""
                changed = true
            }
            if !snapshot.accounts[index].notes.isEmpty {
                snapshot.accounts[index].notes = ""
                changed = true
            }
        }

        if !snapshot.resume.hasStoredAttachment {
            let hadLegacyResumeData = snapshot.resume.sourceFileName != nil ||
                snapshot.resume.attachmentPath != nil ||
                snapshot.resume.attachmentSize != nil ||
                snapshot.resume.importedAt != nil ||
                snapshot.resume.isReady ||
                !snapshot.resume.skills.isEmpty ||
                !snapshot.resume.targetRoles.isEmpty ||
                snapshot.resume.yearsOfExperience != 0 ||
                snapshot.resume.name != "当前简历"
            if hadLegacyResumeData {
                let resumeID = snapshot.resume.id
                snapshot.resume = ResumeProfile(id: resumeID)
                changed = true
            }
        }
        if !snapshot.resume.targetRoles.isEmpty {
            snapshot.resume.targetRoles = []
            changed = true
        }

        let accountsRequiringRebind = duplicateBossIdentityAccountIDs().union(accountsWithUnverifiableLegacyIdentity())
        if !accountsRequiringRebind.isEmpty {
            let remoteIDsRequiringRebind: Set<String> = Set(snapshot.accounts.compactMap { account in
                guard accountsRequiringRebind.contains(account.id) else { return nil }
                return account.remoteProfile?.remoteID.appStoreNonempty
            })
            var usedNames = Set(
                snapshot.accounts
                    .filter { !accountsRequiringRebind.contains($0.id) }
                    .map(\.displayName)
            )
            for index in snapshot.accounts.indices where accountsRequiringRebind.contains(snapshot.accounts[index].id) {
                var sequence = index + 1
                var placeholder = "BOSS 账号 \(sequence)"
                while usedNames.contains(placeholder) {
                    sequence += 1
                    placeholder = "BOSS 账号 \(sequence)"
                }
                usedNames.insert(placeholder)
                snapshot.accounts[index].displayName = placeholder
                snapshot.accounts[index].loginStatus = .loggedOut
                snapshot.accounts[index].lastLoginAt = nil
                snapshot.accounts[index].lastOfficialCheckAt = nil
                snapshot.accounts[index].lastSyncAt = nil
                snapshot.accounts[index].remoteProfile = nil
            }
            snapshot.jobs.removeAll { accountsRequiringRebind.contains($0.accountID) }
            snapshot.conversations.removeAll { accountsRequiringRebind.contains($0.accountID) }
            snapshot.pendingActions.removeAll { accountsRequiringRebind.contains($0.accountID) }
            snapshot.activity.removeAll { entry in
                entry.accountID.map(accountsRequiringRebind.contains) == true
            }
            snapshot.remoteResumeBindings.removeAll {
                accountsRequiringRebind.contains($0.accountID) || remoteIDsRequiringRebind.contains($0.remoteIdentityID)
            }
            snapshot.resumeDeliveryRecords.removeAll {
                accountsRequiringRebind.contains($0.accountID) || remoteIDsRequiringRebind.contains($0.remoteIdentityID)
            }
            snapshot.historyRouteRotationStates.removeAll {
                accountsRequiringRebind.contains($0.accountID) ||
                    remoteIDsRequiringRebind.contains($0.remoteIdentityID)
            }
            snapshot.historyConversationSyncStates.removeAll {
                accountsRequiringRebind.contains($0.accountID) ||
                    remoteIDsRequiringRebind.contains($0.remoteIdentityID)
            }
            changed = true
        }

        let oldJobCount = snapshot.jobs.count
        snapshot.jobs.removeAll { !($0.id.hasPrefix("boss-") || $0.remoteJobID?.isEmpty == false || $0.securityID?.isEmpty == false) }
        changed = changed || snapshot.jobs.count != oldJobCount

        let oldConversationCount = snapshot.conversations.count
        snapshot.conversations.removeAll { !($0.id.hasPrefix("boss-") || $0.remoteConversationID != nil) }
        changed = changed || snapshot.conversations.count != oldConversationCount

        let jobIDs = Set(snapshot.jobs.map(\.id))
        let conversationKeys = Set(snapshot.conversations.map { "\($0.accountID.uuidString)|\($0.id)" })
        let oldActionCount = snapshot.pendingActions.count
        snapshot.pendingActions.removeAll { action in
            if let jobID = action.jobID, !jobIDs.contains(jobID) { return true }
            if let conversationID = action.conversationID,
               !conversationKeys.contains("\(action.accountID.uuidString)|\(conversationID)") { return true }
            return action.jobID == nil && action.conversationID == nil
        }
        changed = changed || snapshot.pendingActions.count != oldActionCount

        if !snapshot.resume.hasStoredAttachment, snapshot.automation.workerEnabled {
            snapshot.automation.workerEnabled = false
            changed = true
        }

        if originalSchemaVersion < 3 {
            for index in snapshot.jobs.indices {
                switch snapshot.jobs[index].stage {
                case .resumeRequested, .resumeSent:
                    snapshot.jobs[index].stage = .discovered
                    snapshot.jobs[index].assessment = nil
                    changed = true
                case .greetingDrafted, .contacted:
                    let job = snapshot.jobs[index]
                    guard let remoteJobID = job.remoteJobID?.appStoreNonempty,
                          let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
                            .remoteProfile?.remoteID.appStoreNonempty else { continue }
                    let attempt = AutomaticGreetingAttempt(
                        accountID: job.accountID,
                        remoteIdentityID: remoteIdentityID,
                        remoteJobID: remoteJobID,
                        attemptedAt: job.capturedAt,
                        succeededAt: job.stage == .contacted ? job.capturedAt : nil
                    )
                    if !snapshot.automaticGreetingAttempts.contains(where: { $0.id == attempt.id }) {
                        snapshot.automaticGreetingAttempts.append(attempt)
                        changed = true
                    }
                default:
                    break
                }
            }
            snapshot.schemaVersion = 3
            changed = true
        }

        if originalSchemaVersion < 4 {
            snapshot.preferences.targetRoles = []
            snapshot.preferences.cities = []
            snapshot.preferences.bossCityCode = ""
            snapshot.preferences.requiredKeywords = []
            snapshot.preferences.preferredKeywords = []
            snapshot.preferences.excludedKeywords = []
            snapshot.preferences.minimumSalaryK = nil
            snapshot.preferences.maximumSalaryK = nil
            snapshot.preferences.requireFullJobDescription = false
            snapshot.preferences.plannedSearchQueries = []
            snapshot.preferences.plannedCities = []
            snapshot.preferences.planGeneratedAt = nil
            snapshot.preferences.planProvider = ""
            snapshot.schemaVersion = 4
            changed = true
        }

        if originalSchemaVersion < 5 {
            // 迁移时归一化每日额度，不扩大旧配置的写入许可。
            snapshot.automation.dailyGreetingLimit = AutomationSettings.normalizedDailyGreetingLimit(
                snapshot.automation.dailyGreetingLimit
            )
            snapshot.schemaVersion = 5
            changed = true
        }

        if originalSchemaVersion < 6 {
            snapshot.schemaVersion = 6
            changed = true
        }

        if originalSchemaVersion < 7 {
            // 重存时移除旧 connectorCooldownUntil，保留独立的额度及间隔账本。
            snapshot.schemaVersion = 7
            changed = true
        }

        if originalSchemaVersion < 8 {
            // 旧版开关不代表已授权可用的发送能力，升级后须重新开启。
            snapshot.automation.automaticallySendResume = false
            snapshot.schemaVersion = 8
            changed = true
        }

        if originalSchemaVersion < 9 {
            snapshot.schemaVersion = 9
            changed = true
        }

        if originalSchemaVersion < 10 {
            snapshot.schemaVersion = 10
            changed = true
        }

        if originalSchemaVersion < 11 {
            // 旧游标缺少续页 page，只重置不完整分页状态，从最新历史重建。
            for index in snapshot.historyConversationSyncStates.indices {
                snapshot.historyConversationSyncStates[index].gapCursorMID = nil
                snapshot.historyConversationSyncStates[index].gapTargetMID = nil
                snapshot.historyConversationSyncStates[index].gapNewHeadMID = nil
                snapshot.historyConversationSyncStates[index].gapNextPage = 1
                snapshot.historyConversationSyncStates[index].backfillCursorMID = nil
                snapshot.historyConversationSyncStates[index].backfillNextPage = 1
            }
            snapshot.schemaVersion = 11
            changed = true
        }

        if originalSchemaVersion < 12 {
            // 缺少权威详情的可逆匹配结果需重评；保留已外发阶段及其防重账本。
            let invalidatedJobIDs = Set(snapshot.jobs.compactMap { job -> String? in
                guard !job.hasAuthoritativeDescription,
                      job.stage == .recommended || job.stage == .rejected else { return nil }
                return job.id
            })
            for index in snapshot.jobs.indices where invalidatedJobIDs.contains(snapshot.jobs[index].id) {
                snapshot.jobs[index].stage = .discovered
                snapshot.jobs[index].assessment = nil
            }
            snapshot.pendingActions.removeAll {
                $0.kind == .sendGreeting && $0.jobID.map(invalidatedJobIDs.contains) == true
            }
            snapshot.schemaVersion = 12
            changed = true
        }

        if originalSchemaVersion < 13 {
            // 将旧分钟间隔迁移为秒级配置，使用统一默认值。
            snapshot.automation.greetingIntervalSeconds = AutomationSettings.defaultGreetingIntervalSeconds
            snapshot.schemaVersion = 13
            changed = true
        }

        if originalSchemaVersion < 14 {
            // 启用完整自动检索能力，归一化间隔并保留每日上限。
            snapshot.automation.greetingIntervalSeconds =
                AutomationSettings.normalizedGreetingIntervalSeconds(
                    snapshot.automation.greetingIntervalSeconds
                )
            snapshot.automation.enforceAutomaticModeCapabilities()
            snapshot.schemaVersion = 14
            changed = true
        }

        if originalSchemaVersion < 15 {
            // 兼容 schema 15 的历史两分钟间隔，后续版本再统一迁移。
            snapshot.automation.greetingIntervalSeconds = 120
            snapshot.schemaVersion = 15
            changed = true
        }

        if originalSchemaVersion < 16 {
            // 将旧两分钟默认值归一化，保留更慢的显式配置。
            if snapshot.automation.greetingIntervalSeconds == 120 {
                snapshot.automation.greetingIntervalSeconds =
                    AutomationSettings.defaultGreetingIntervalSeconds
            } else {
                snapshot.automation.greetingIntervalSeconds =
                    AutomationSettings.normalizedGreetingIntervalSeconds(
                        snapshot.automation.greetingIntervalSeconds
                    )
            }
            snapshot.schemaVersion = 16
            changed = true
        }

        if originalSchemaVersion < 17 {
            // 薪资匹配规则更新后重评可逆结果，保留已尝试及已确认的外发记录。
            let invalidatedJobIDs = Set(snapshot.jobs.compactMap { job -> String? in
                job.stage == .recommended || job.stage == .rejected ? job.id : nil
            })
            for index in snapshot.jobs.indices where invalidatedJobIDs.contains(snapshot.jobs[index].id) {
                snapshot.jobs[index].stage = .discovered
                snapshot.jobs[index].assessment = nil
            }
            snapshot.pendingActions.removeAll {
                $0.kind == .sendGreeting &&
                    $0.status.requiresAttention &&
                    $0.jobID.map(invalidatedJobIDs.contains) == true
            }
            snapshot.schemaVersion = 17
            changed = true
        }

        if originalSchemaVersion < 18 {
            // 将旧一分钟默认值归一化，保留更慢的显式配置。
            if snapshot.automation.greetingIntervalSeconds == 60 {
                snapshot.automation.greetingIntervalSeconds =
                    AutomationSettings.defaultGreetingIntervalSeconds
            } else {
                snapshot.automation.greetingIntervalSeconds =
                    AutomationSettings.normalizedGreetingIntervalSeconds(
                        snapshot.automation.greetingIntervalSeconds
                    )
            }
            snapshot.schemaVersion = 18
            changed = true
        }

        if originalSchemaVersion < 19 {
            // 将旧十五分钟检索默认值归一化，保留更慢的显式配置。
            if snapshot.automation.searchIntervalMinutes == 15 {
                snapshot.automation.searchIntervalMinutes =
                    AutomationSettings.defaultSearchIntervalMinutes
            } else {
                snapshot.automation.searchIntervalMinutes =
                    AutomationSettings.normalizedSearchIntervalMinutes(
                        snapshot.automation.searchIntervalMinutes
                    )
            }
            snapshot.schemaVersion = 19
            changed = true
        }

        if originalSchemaVersion < 20 {
            // 岗位方向匹配规则更新后重评可逆结果，已外发记录继续受防重保护。
            let invalidatedJobIDs = Set(snapshot.jobs.compactMap { job -> String? in
                job.stage == .recommended || job.stage == .rejected ? job.id : nil
            })
            for index in snapshot.jobs.indices where invalidatedJobIDs.contains(snapshot.jobs[index].id) {
                snapshot.jobs[index].stage = .discovered
                snapshot.jobs[index].assessment = nil
            }
            snapshot.pendingActions.removeAll {
                $0.kind == .sendGreeting &&
                    $0.status.requiresAttention &&
                    $0.jobID.map(invalidatedJobIDs.contains) == true
            }
            snapshot.schemaVersion = 20
            changed = true
        }

        if originalSchemaVersion < 21 {
            // 将旧高频默认值迁移到保守配置，保留更慢的显式设置。
            if snapshot.automation.monitorIntervalMinutes <= 15 {
                snapshot.automation.monitorIntervalMinutes =
                    AutomationSettings.defaultMonitorIntervalMinutes
            } else {
                snapshot.automation.monitorIntervalMinutes =
                    AutomationSettings.normalizedMonitorIntervalMinutes(
                        snapshot.automation.monitorIntervalMinutes
                    )
            }
            if snapshot.automation.searchIntervalMinutes <= 15 {
                snapshot.automation.searchIntervalMinutes =
                    AutomationSettings.defaultSearchIntervalMinutes
            } else {
                snapshot.automation.searchIntervalMinutes =
                    AutomationSettings.normalizedSearchIntervalMinutes(
                        snapshot.automation.searchIntervalMinutes
                    )
            }
            if snapshot.automation.greetingIntervalSeconds <=
                AutomationSettings.greetingIntervalSecondsRange.lowerBound {
                snapshot.automation.greetingIntervalSeconds =
                    AutomationSettings.defaultGreetingIntervalSeconds
            } else {
                snapshot.automation.greetingIntervalSeconds =
                    AutomationSettings.normalizedGreetingIntervalSeconds(
                        snapshot.automation.greetingIntervalSeconds
                    )
            }
            if snapshot.automation.dailyGreetingLimit >=
                AutomationSettings.dailyGreetingLimitRange.upperBound {
                snapshot.automation.dailyGreetingLimit =
                    AutomationSettings.defaultDailyGreetingLimit
            } else {
                snapshot.automation.dailyGreetingLimit =
                    AutomationSettings.normalizedDailyGreetingLimit(
                        snapshot.automation.dailyGreetingLimit
                    )
            }
            snapshot.schemaVersion = 21
            changed = true
        }

        if originalSchemaVersion < 22 {
            // 清除旧版遗留的本人验证锁，保留会话、业务数据和安全账本。
            for index in snapshot.accounts.indices
                where snapshot.accounts[index].manualVerificationChallenge != nil {
                snapshot.accounts[index].manualVerificationChallenge = nil
                changed = true
            }
            snapshot.schemaVersion = 22
            changed = true
        }

        if originalSchemaVersion < 23 {
            // 恢复每账号默认每日额度；保留此版本的历史间隔供后续迁移。
            snapshot.automation.dailyGreetingLimit =
                AutomationSettings.defaultDailyGreetingLimit
            snapshot.automation.greetingIntervalSeconds = 120
            snapshot.schemaVersion = 23
            changed = true
        }

        if originalSchemaVersion < 24 {
            // 将旧间隔迁移到统一默认值，仍保持串行投递。
            snapshot.automation.greetingIntervalSeconds =
                AutomationSettings.defaultGreetingIntervalSeconds
            snapshot.schemaVersion = 24
            changed = true
        }

        if originalSchemaVersion < 25 {
            // 提高旧配置的检索和监控间隔并停止后台运行，保留更保守设置和安全账本。
            snapshot.automation.monitorIntervalMinutes = max(
                snapshot.automation.monitorIntervalMinutes, AutomationSettings.defaultMonitorIntervalMinutes
            )
            snapshot.automation.searchIntervalMinutes = max(
                snapshot.automation.searchIntervalMinutes, AutomationSettings.defaultSearchIntervalMinutes
            )
            snapshot.automation.workerEnabled = false
            snapshot.schemaVersion = 25
            changed = true
        }

        if snapshot.preferences.hasSearchCriteria,
           !snapshot.preferences.plannedSearchQueries.isEmpty {
            let normalizedPlan = JobSearchPlanningPolicy.normalizedSearchPlan(
                queries: snapshot.preferences.plannedSearchQueries,
                requirementText: snapshot.preferences.requirementText,
                provider: snapshot.preferences.planProvider
            )
            if normalizedPlan.queries != snapshot.preferences.plannedSearchQueries ||
                normalizedPlan.cities != snapshot.preferences.plannedCities {
                snapshot.preferences.plannedSearchQueries = normalizedPlan.queries
                snapshot.preferences.plannedCities = normalizedPlan.cities
                changed = true
            }
        }

        var seenGreetingAttempts = Set<String>()
        let deduplicatedGreetingAttempts = snapshot.automaticGreetingAttempts
            .sorted { $0.attemptedAt < $1.attemptedAt }
            .filter { seenGreetingAttempts.insert($0.id).inserted }
        if deduplicatedGreetingAttempts != snapshot.automaticGreetingAttempts {
            snapshot.automaticGreetingAttempts = deduplicatedGreetingAttempts
            changed = true
        }
        var seenGreetingSafetyRecords = Set<String>()
        let deduplicatedGreetingSafetyRecords = (
            snapshot.automaticGreetingSafetyRecords +
            snapshot.automaticGreetingAttempts.map { AutomaticGreetingSafetyRecord(attempt: $0) }
        )
        .sorted { $0.attemptedAt < $1.attemptedAt }
        .filter { seenGreetingSafetyRecords.insert($0.id).inserted }
        if deduplicatedGreetingSafetyRecords != snapshot.automaticGreetingSafetyRecords {
            snapshot.automaticGreetingSafetyRecords = deduplicatedGreetingSafetyRecords
            changed = true
        }
        var seenResumeConsentSafetyRecords = Set<String>()
        let deduplicatedResumeConsentSafetyRecords = (
            snapshot.resumeConsentSafetyRecords +
            snapshot.resumeDeliveryRecords.map(ResumeConsentSafetyRecord.init(record:))
        )
        .sorted { $0.preparedAt < $1.preparedAt }
        .filter { seenResumeConsentSafetyRecords.insert($0.id).inserted }
        if deduplicatedResumeConsentSafetyRecords != snapshot.resumeConsentSafetyRecords {
            snapshot.resumeConsentSafetyRecords = deduplicatedResumeConsentSafetyRecords
            changed = true
        }
        let ownedGreetingAttempts = normalizedAutomaticGreetingAttemptsForCurrentOwners()
        if ownedGreetingAttempts != snapshot.automaticGreetingAttempts {
            snapshot.automaticGreetingAttempts = ownedGreetingAttempts
            changed = true
        }
        if normalizeResumeDeliveryOwnership() {
            changed = true
        }
        if normalizeHistorySyncOwnership() {
            changed = true
        }
        return changed
    }

    private func normalizeAutomaticGreetingAttemptOwners() {
        snapshot.automaticGreetingAttempts = normalizedAutomaticGreetingAttemptsForCurrentOwners()
    }

    private func normalizedAutomaticGreetingAttemptsForCurrentOwners() -> [AutomaticGreetingAttempt] {
        let ownerByIdentity = Dictionary(
            snapshot.accounts.compactMap { account -> (String, UUID)? in
                guard let remoteID = account.remoteProfile?.remoteID.appStoreNonempty else { return nil }
                return (remoteID, account.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return snapshot.automaticGreetingAttempts.compactMap { attempt in
            guard let ownerID = ownerByIdentity[attempt.remoteIdentityID] else { return nil }
            var ownedAttempt = attempt
            ownedAttempt.accountID = ownerID
            return ownedAttempt
        }
    }

    @discardableResult
    private func normalizeResumeDeliveryOwnership() -> Bool {
        let previousBindings = snapshot.remoteResumeBindings
        let previousRecords = snapshot.resumeDeliveryRecords
        let remoteIdentityByAccount = Dictionary(
            uniqueKeysWithValues: snapshot.accounts.compactMap { account -> (UUID, String)? in
                guard let remoteIdentityID = account.remoteProfile?.remoteID.appStoreNonempty else { return nil }
                return (account.id, remoteIdentityID)
            }
        )

        var seenBindingIDs = Set<String>()
        snapshot.remoteResumeBindings = snapshot.remoteResumeBindings
            .sorted { $0.uploadedAt > $1.uploadedAt }
            .compactMap { binding in
                let remoteIdentityID = binding.remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard remoteIdentityByAccount[binding.accountID] == remoteIdentityID,
                      let attachmentSHA256 = ResumeDeliveryDigestPolicy.normalizedAttachmentSHA256(
                        binding.attachmentSHA256
                      ) else { return nil }
                let remoteResumeToken = binding.remoteResumeToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !remoteResumeToken.isEmpty, remoteResumeToken.count <= 4_096 else { return nil }
                var normalized = binding
                normalized.remoteIdentityID = remoteIdentityID
                normalized.attachmentSHA256 = attachmentSHA256
                normalized.remoteResumeToken = remoteResumeToken
                normalized.remoteDisplayName = binding.remoteDisplayName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .appStoreNonempty
                    .map { String($0.prefix(255)) }
                guard seenBindingIDs.insert(normalized.id).inserted else { return nil }
                return normalized
            }
            .sorted { $0.id < $1.id }

        var seenConsentIDs = Set<String>()
        snapshot.resumeDeliveryRecords = snapshot.resumeDeliveryRecords
            .filter { remoteIdentityByAccount[$0.accountID] == $0.remoteIdentityID }
            .sorted { lhs, rhs in
                let lhsRank = resumeDeliverySafetyRank(lhs.state)
                let rhsRank = resumeDeliverySafetyRank(rhs.state)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .filter { seenConsentIDs.insert($0.consentIdentifier).inserted }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }

        return previousBindings != snapshot.remoteResumeBindings ||
            previousRecords != snapshot.resumeDeliveryRecords
    }

    @discardableResult
    private func normalizeHistorySyncOwnership() -> Bool {
        let previousRotations = snapshot.historyRouteRotationStates
        let previousConversations = snapshot.historyConversationSyncStates
        let remoteIdentityByAccount = Dictionary(
            uniqueKeysWithValues: snapshot.accounts.compactMap { account -> (UUID, String)? in
                guard let remoteIdentityID = account.remoteProfile?.remoteID.appStoreNonempty else {
                    return nil
                }
                return (account.id, remoteIdentityID)
            }
        )
        let conversationOwner = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.map { ($0.id, $0.accountID) }
        )

        var seenRotationIDs = Set<String>()
        snapshot.historyRouteRotationStates = snapshot.historyRouteRotationStates
            .filter { remoteIdentityByAccount[$0.accountID] == $0.remoteIdentityID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seenRotationIDs.insert($0.id).inserted }
            .map { state in
                var state = state
                state.unresolvedOffset = max(0, state.unresolvedOffset)
                state.regularOffset = max(0, state.regularOffset)
                return state
            }
            .sorted { $0.id < $1.id }

        var seenConversationIDs = Set<String>()
        snapshot.historyConversationSyncStates = snapshot.historyConversationSyncStates
            .filter { state in
                remoteIdentityByAccount[state.accountID] == state.remoteIdentityID &&
                    conversationOwner[state.conversationID] == state.accountID
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { state in
                var state = state
                state.latestHeadMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.latestHeadMID)
                state.gapCursorMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.gapCursorMID)
                state.gapTargetMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.gapTargetMID)
                state.gapNewHeadMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.gapNewHeadMID)
                state.backfillCursorMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.backfillCursorMID)
                if state.gapCursorMID == nil || state.gapNextPage < 2 {
                    state.gapCursorMID = nil
                    state.gapTargetMID = nil
                    state.gapNewHeadMID = nil
                    state.gapNextPage = 1
                }
                if state.backfillCursorMID == nil || state.backfillNextPage < 2 {
                    state.backfillCursorMID = nil
                    state.backfillNextPage = 1
                }
                guard seenConversationIDs.insert(state.id).inserted else { return nil }
                return state
            }
            .sorted { $0.id < $1.id }

        return previousRotations != snapshot.historyRouteRotationStates ||
            previousConversations != snapshot.historyConversationSyncStates
    }

    private func resumeDeliverySafetyRank(_ state: ResumeDeliveryState) -> Int {
        switch state {
        case .confirmed: 7
        case .requestCreatedAwaitingRecruiter, .serverAcceptedUnverified: 6
        case .dispatching: 5
        case .failed: 4
        case .cancelled: 3
        case .preparingAttachment: 2
        case .queued: 1
        }
    }

    /// 同一远端身份仅保留最早账号槽位，重复槽位须重新扫码。
    private func duplicateBossIdentityAccountIDs() -> Set<UUID> {
        let orderedAccounts = snapshot.accounts.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var seenRemoteIDs = Set<String>()
        var duplicates = Set<UUID>()
        for account in orderedAccounts {
            let remoteID = account.remoteProfile?.remoteID
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !remoteID.isEmpty else { continue }
            if !seenRemoteIDs.insert(remoteID).inserted {
                duplicates.insert(account.id)
            }
        }
        return duplicates
    }

    /// 缺少稳定身份的旧记录无法安全归属，新扫码身份须从空数据重新绑定。
    private func accountsWithUnverifiableLegacyIdentity() -> Set<UUID> {
        Set(snapshot.accounts.compactMap { account in
            let remoteID = account.remoteProfile?.remoteID
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard remoteID.isEmpty else { return nil }
            let hasRemoteData = snapshot.jobs.contains(where: { $0.accountID == account.id }) ||
                snapshot.conversations.contains(where: { $0.accountID == account.id }) ||
                snapshot.pendingActions.contains(where: { $0.accountID == account.id })
            return account.remoteProfile != nil || hasRemoteData ? account.id : nil
        })
    }

    @discardableResult
    func applyBossProfile(_ incomingProfile: BossAccountProfile, accountID: UUID) throws -> Bool {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw BossAccountBindingError.accountMissing
        }
        let profile = incomingProfile
        let incomingRemoteID = profile.remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousRemoteID = snapshot.accounts[index].remoteProfile?.remoteID
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !incomingRemoteID.isEmpty,
           let duplicate = snapshot.accounts.first(where: {
               $0.id != accountID &&
               $0.remoteProfile?.remoteID.trimmingCharacters(in: .whitespacesAndNewlines) == incomingRemoteID
           }) {
            throw BossAccountBindingError.duplicateIdentity(duplicate.selectionLabel(in: snapshot.accounts))
        }
        if incomingRemoteID.isEmpty {
            throw BossAccountBindingError.remoteIdentityMissing
        }
        let previousSnapshot = snapshot
        let previousSelectedJobID = selectedJobID
        let previousSelectedConversationID = selectedConversationID

        // 防重键属于远端身份；绑定时统一旧记录，避免槽位切换后遗留错误归属。
        for attemptIndex in snapshot.automaticGreetingAttempts.indices
        where snapshot.automaticGreetingAttempts[attemptIndex].remoteIdentityID == incomingRemoteID {
            snapshot.automaticGreetingAttempts[attemptIndex].accountID = accountID
        }

        let hasUnboundRemoteData = previousRemoteID.isEmpty && (
            snapshot.jobs.contains(where: { $0.accountID == accountID }) ||
            snapshot.conversations.contains(where: { $0.accountID == accountID }) ||
            snapshot.pendingActions.contains(where: { $0.accountID == accountID }) ||
            snapshot.remoteResumeBindings.contains(where: { $0.accountID == accountID }) ||
            snapshot.resumeDeliveryRecords.contains(where: { $0.accountID == accountID })
        )
        let identityChanged = (!previousRemoteID.isEmpty && incomingRemoteID != previousRemoteID) || hasUnboundRemoteData
        if identityChanged {
            snapshot.jobs.removeAll { $0.accountID == accountID }
            snapshot.conversations.removeAll { $0.accountID == accountID }
            snapshot.pendingActions.removeAll { $0.accountID == accountID }
            snapshot.activity.removeAll { $0.accountID == accountID }
            snapshot.remoteResumeBindings.removeAll {
                $0.accountID == accountID || (!previousRemoteID.isEmpty && $0.remoteIdentityID == previousRemoteID)
            }
            snapshot.resumeDeliveryRecords.removeAll {
                $0.accountID == accountID || (!previousRemoteID.isEmpty && $0.remoteIdentityID == previousRemoteID)
            }
            snapshot.historyRouteRotationStates.removeAll {
                $0.accountID == accountID || (!previousRemoteID.isEmpty && $0.remoteIdentityID == previousRemoteID)
            }
            snapshot.historyConversationSyncStates.removeAll {
                $0.accountID == accountID || (!previousRemoteID.isEmpty && $0.remoteIdentityID == previousRemoteID)
            }
            if selectedJobID.flatMap({ selectedID in snapshot.jobs.first(where: { $0.id == selectedID }) }) == nil {
                selectedJobID = nil
            }
            if selectedConversationID.flatMap({ selectedID in snapshot.conversations.first(where: { $0.id == selectedID }) }) == nil {
                selectedConversationID = nil
            }
        }

        snapshot.accounts[index].remoteProfile = profile
        if !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshot.accounts[index].displayName = profile.name
        }
        snapshot.accounts[index].lastSyncAt = profile.syncedAt
        normalizeAutomaticGreetingAttemptOwners()
        if identityChanged {
            appendActivity(
                accountID: accountID,
                level: .warning,
                title: "已切换 BOSS 身份",
                detail: "检测到该本地账号登录了新的 BOSS 身份，旧身份的岗位、消息和草稿已清理。"
            )
        }
        if identityChanged {
            saveTask?.cancel()
            saveTask = nil
            do {
                try persistence.save(snapshot)
            } catch {
                snapshot = previousSnapshot
                selectedJobID = previousSelectedJobID
                selectedConversationID = previousSelectedConversationID
                throw error
            }
        } else {
            scheduleSave()
        }
        return identityChanged
    }

    func beginRequirementsEditing() {
        guard requirementsDraft == nil else { return }
        let draft = JobRequirementsDraft(preferences: snapshot.preferences)
        savedRequirementsDraft = draft
        requirementsDraft = draft
    }

    func finishRequirementsEditing() {
        guard !hasUnsavedRequirementsChanges, !isSavingRequirements else { return }
        requirementsDraft = nil
        savedRequirementsDraft = nil
        isEditingRequirements = false
    }

    func discardRequirementsChanges() {
        guard !isSavingRequirements, let saved = savedRequirementsDraft else { return }
        // 保存失败前可能已更新内存偏好，仍需恢复原状态。
        updatePreferences {
            $0.requirementText = saved.requirementText
            $0.greetingTemplate = saved.greetingTemplate
        }
        requirementsDraft = saved
        isEditingRequirements = false
    }

    @discardableResult
    func saveRequirementsChanges() async -> Bool {
        guard !isSavingRequirements else { return false }
        guard hasUnsavedRequirementsChanges, let draft = requirementsDraft else { return true }
        guard !persistenceBlocked else {
            lastError = "本地数据不可写，修改尚未保存。"
            return false
        }
        isSavingRequirements = true
        defer { isSavingRequirements = false }
        updatePreferences {
            $0.requirementText = draft.requirementText
            $0.greetingTemplate = draft.greetingTemplate
        }
        saveTask?.cancel()
        saveTask = nil
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                persistence.saveInBackground(snapshot) { continuation.resume(with: $0) }
            }
            savedRequirementsDraft = draft
            return !hasUnsavedRequirementsChanges
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func updatePreferences(_ transform: (inout JobPreferences) -> Void) {
        var updated = snapshot
        let previous = updated.preferences
        transform(&updated.preferences)
        if updated.preferences != previous {
            if updated.preferences.requirementText != previous.requirementText {
                updated.preferences.plannedSearchQueries = []
                updated.preferences.plannedCities = []
                updated.preferences.planGeneratedAt = nil
                updated.preferences.planProvider = ""
            }
            invalidateMatchingResults(in: &updated)
            snapshot = updated
        }
        scheduleSave()
    }

    func updateCodex(_ transform: (inout CodexConfiguration) -> Void) {
        transform(&snapshot.codex)
        scheduleSave()
    }

    func updateAutomation(_ transform: (inout AutomationSettings) -> Void) {
        transform(&snapshot.automation)
        snapshot.automation.enforceAutomaticModeCapabilities()
        snapshot.automation.monitorIntervalMinutes = AutomationSettings.normalizedMonitorIntervalMinutes(
            snapshot.automation.monitorIntervalMinutes
        )
        snapshot.automation.searchIntervalMinutes = AutomationSettings.normalizedSearchIntervalMinutes(
            snapshot.automation.searchIntervalMinutes
        )
        snapshot.automation.dailyGreetingLimit = AutomationSettings.normalizedDailyGreetingLimit(
            snapshot.automation.dailyGreetingLimit
        )
        snapshot.automation.greetingIntervalSeconds = AutomationSettings.normalizedGreetingIntervalSeconds(
            snapshot.automation.greetingIntervalSeconds
        )
        scheduleSave()
    }

    /// 首次招聘方可见写入前持久化单次同意许可；附件准备不消耗许可，更换附件也不能重用 MID。
    @discardableResult
    func allowsAutomaticResumeDelivery(accountID: UUID, conversationID: String) -> Bool {
        guard !isEditingRequirements,
              let conversation = snapshot.conversations.first(where: {
                  $0.accountID == accountID && ($0.id == conversationID || $0.remoteConversationID == conversationID)
              }) else { return false }
        guard JobMatchingPolicy.matchingExclusions(
            in: conversation.company + "\n" + conversation.jobTitle,
            preferences: snapshot.preferences
        ).isEmpty else { return false }
        let linkedJobs = snapshot.jobs.filter {
            $0.accountID == accountID && (
                (conversation.securityID?.appStoreNonempty != nil && $0.securityID == conversation.securityID) ||
                conversationMatchesJob(conversation, job: $0)
            )
        }
        guard !linkedJobs.isEmpty || !JobMatchingPolicy.requiresRecruitmentEvidence(preferences: snapshot.preferences)
        else { return false }
        return linkedJobs.allSatisfy {
            JobMatchingPolicy.hardGateFailures(job: $0, preferences: snapshot.preferences).isEmpty
        }
    }

    func prepareResumeDelivery(
        evidence: ResumeConsentEvidence,
        attachmentSHA256: String,
        now: Date = Date()
    ) throws -> ResumeDeliveryRecord {
        try persistResumeDeliveryMutation {
            guard evidence.isAuthoritative else {
                throw ResumeDeliveryStoreError.evidenceNotAuthoritative
            }
            let safetyRecord = ResumeConsentSafetyRecord(evidence: evidence, preparedAt: now)
            guard !snapshot.resumeConsentSafetyRecords.contains(where: { $0.id == safetyRecord.id }),
                  !snapshot.resumeDeliveryRecords.contains(where: {
                    $0.remoteIdentityID == evidence.remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines) &&
                        $0.triggerRemoteMID == evidence.triggerRemoteMID.trimmingCharacters(in: .whitespacesAndNewlines)
                  }) else {
                throw ResumeDeliveryStoreError.duplicateConsent
            }
            guard let normalizedAttachmentSHA256 = ResumeDeliveryDigestPolicy
                .normalizedAttachmentSHA256(attachmentSHA256) else {
                throw ResumeDeliveryStoreError.invalidAttachmentDigest
            }
            let remoteIdentityID = evidence.remoteIdentityID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let account = snapshot.accounts.first(where: {
                $0.id == evidence.accountID &&
                    $0.status == .active &&
                    $0.remoteProfile?.remoteID.appStoreNonempty == remoteIdentityID
            }) else {
                throw ResumeDeliveryStoreError.accountIdentityMismatch
            }
            let conversationID = evidence.conversationID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard snapshot.conversations.contains(where: { conversation in
                conversation.accountID == account.id &&
                    (conversation.id == conversationID || conversation.remoteConversationID == conversationID)
            }) else {
                throw ResumeDeliveryStoreError.conversationMismatch
            }
            guard !resumeDeliveryAlreadyExists(
                accountID: account.id,
                remoteIdentityID: remoteIdentityID,
                conversationID: conversationID
            ) else {
                throw ResumeDeliveryStoreError.deliveryAlreadyExists
            }
            guard authoritativeResumeConsentCandidates(accountID: evidence.accountID).contains(evidence) else {
                throw ResumeDeliveryStoreError.evidenceNotCurrentHistory
            }

            let record = ResumeDeliveryRecord(
                evidence: evidence,
                attachmentSHA256: normalizedAttachmentSHA256,
                now: now
            )
            guard !snapshot.resumeDeliveryRecords.contains(where: {
                $0.id == record.id || $0.consentIdentifier == record.consentIdentifier
            }) else {
                throw ResumeDeliveryStoreError.duplicateConsent
            }
            snapshot.resumeDeliveryRecords.append(record)
            snapshot.resumeConsentSafetyRecords.append(safetyRecord)
            return record
        }
    }

    /// 以唯一原生卡片原子推进同一条 type-3 投递链，并在接受写入前追加卡片 MID 的安全记录。
    @discardableResult
    func promoteResumeDeliveryToNativeDispatch(
        recordID: String,
        evidence: ResumeConsentEvidence,
        remoteResumeToken: String,
        writeBaselineRemoteMID: String? = nil,
        now: Date = Date()
    ) throws -> ResumeDeliveryRecord {
        try persistResumeDeliveryMutation {
            guard evidence.isAuthoritativeNativeRequest else {
                throw ResumeDeliveryStoreError.evidenceNotAuthoritative
            }
            let remoteIdentityID = evidence.remoteIdentityID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let conversationID = evidence.conversationID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let triggerRemoteMID = evidence.triggerRemoteMID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard snapshot.accounts.contains(where: {
                $0.id == evidence.accountID &&
                    $0.status == .active &&
                    $0.remoteProfile?.remoteID.appStoreNonempty == remoteIdentityID
            }) else {
                throw ResumeDeliveryStoreError.accountIdentityMismatch
            }

            let unresolved = snapshot.resumeDeliveryRecords.enumerated().filter { _, candidate in
                candidate.accountID == evidence.accountID &&
                    candidate.remoteIdentityID == remoteIdentityID &&
                    candidate.conversationID == conversationID &&
                    candidate.exchangeKind == .requestRecruiterConfirmation &&
                    candidate.state == .requestCreatedAwaitingRecruiter
            }
            guard unresolved.count == 1,
                  let (index, existing) = unresolved.first,
                  existing.id == recordID,
                  let originalServerAcceptedAt = existing.serverAcceptedAt,
                  evidence.receivedAt >= originalServerAcceptedAt,
                  ResumeDeliveryDigestPolicy.remoteMID(
                    triggerRemoteMID,
                    isStrictlyNewerThan: existing.writeBaselineRemoteMID ?? existing.triggerRemoteMID
                  ),
                  existing.triggerRemoteMID != triggerRemoteMID else {
                throw ResumeDeliveryStoreError.invalidNativePromotion
            }
            let promotableNativeEvidence = authoritativeResumeConsentCandidates(
                accountID: evidence.accountID
            ).filter { candidate in
                candidate.isAuthoritativeNativeRequest &&
                    candidate.remoteIdentityID == remoteIdentityID &&
                    candidate.conversationID == conversationID &&
                    candidate.receivedAt >= originalServerAcceptedAt
            }
            guard promotableNativeEvidence.count == 1,
                  promotableNativeEvidence[0] == evidence else {
                throw ResumeDeliveryStoreError.evidenceNotCurrentHistory
            }

            let nativeSafety = ResumeConsentSafetyRecord(evidence: evidence, preparedAt: now)
            guard !snapshot.resumeConsentSafetyRecords.contains(where: { $0.id == nativeSafety.id }) else {
                throw ResumeDeliveryStoreError.duplicateConsent
            }
            let normalizedToken = remoteResumeToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty,
                  normalizedToken.count <= 4_096,
                  existing.remoteResumeToken?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedToken,
                  snapshot.remoteResumeBindings.contains(where: { binding in
                    binding.accountID == existing.accountID &&
                        binding.remoteIdentityID == existing.remoteIdentityID &&
                        binding.attachmentSHA256 == existing.attachmentSHA256 &&
                        binding.remoteResumeToken == normalizedToken
                  }) else {
                throw ResumeDeliveryStoreError.remoteResumeBindingMissing
            }

            var promoted = existing
            promoted.id = ResumeDeliveryRecord.identifier(
                remoteIdentityID: remoteIdentityID,
                conversationID: conversationID,
                triggerRemoteMID: triggerRemoteMID,
                attachmentSHA256: existing.attachmentSHA256
            )
            promoted.triggerRemoteMID = triggerRemoteMID
            promoted.triggerTextDigest = evidence.triggerTextDigest
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            promoted.exchangeKind = .acceptNativeRequest
            promoted.nativeActionAID = evidence.nativeActionAID
            promoted.nativeScene = evidence.nativeScene
            promoted.nativeDialogType = evidence.nativeDialogType
            promoted.nativeDialogWasOperated = evidence.nativeDialogWasOperated
            promoted.remoteResumeToken = normalizedToken
            promoted.writeStartedAt = now
            promoted.writeBaselineRemoteMID = try normalizedResumeWriteBaselineMID(
                writeBaselineRemoteMID
            )
            promoted.state = .dispatching
            promoted.updatedAt = now
            promoted.serverAcceptedAt = nil
            promoted.verifiedAt = nil
            promoted.failureCode = nil

            guard !snapshot.resumeDeliveryRecords.enumerated().contains(where: { candidateIndex, candidate in
                candidateIndex != index &&
                    (candidate.id == promoted.id || candidate.consentIdentifier == promoted.consentIdentifier)
            }) else {
                throw ResumeDeliveryStoreError.duplicateConsent
            }
            snapshot.resumeDeliveryRecords[index] = promoted
            snapshot.resumeConsentSafetyRecords.append(nativeSafety)
            return promoted
        }
    }

    func resumeDeliveryRecord(id: String) -> ResumeDeliveryRecord? {
        snapshot.resumeDeliveryRecords.first { $0.id == id }
    }

    /// BOSS 接受附件发送或历史确认附件发出即计入交换，包含手动发送。
    func hasResumeExchange(for job: JobListing) -> Bool {
        if let cached = resumeExchangeJobs[job.id], cached.job == job { return cached.exchanged }

        if resumeExchangeConversations == nil {
            var sentIDs: [UUID: Set<String>] = [:]
            var acceptedDates: [UUID: [String: Date]] = [:]
            for record in snapshot.resumeDeliveryRecords where record.state.countsAsResumeExchange {
                sentIDs[record.accountID, default: []].insert(record.conversationID)
                if let date = record.serverAcceptedAt {
                    let previous = acceptedDates[record.accountID]?[record.conversationID] ?? .distantPast
                    acceptedDates[record.accountID, default: [:]][record.conversationID] = max(previous, date)
                }
            }
            var securityIDs: [UUID: Set<String>] = [:]
            var byCompany: [UUID: [String: [(conversation: Conversation, sentAt: Date?)]]] = [:]
            var datesBySecurityID: [UUID: [String: Date]] = [:]
            for conversation in snapshot.conversations {
                let aliases = [conversation.id, conversation.remoteConversationID].compactMap { $0 }
                guard aliases.contains(where: { sentIDs[conversation.accountID]?.contains($0) == true }) ||
                        conversation.messages.contains(where: \.showsSentResumeAttachment) else { continue }
                let date = (aliases.compactMap { acceptedDates[conversation.accountID]?[$0] } +
                            conversation.messages.compactMap(\.resumeAttachmentSentAt)).max()
                if let securityID = conversation.securityID?.appStoreNonempty {
                    securityIDs[conversation.accountID, default: []].insert(securityID)
                    if let date {
                        let previous = datesBySecurityID[conversation.accountID]?[securityID] ?? .distantPast
                        datesBySecurityID[conversation.accountID, default: [:]][securityID] = max(previous, date)
                    }
                }
                byCompany[conversation.accountID, default: [:]][normalizedJobIdentity(conversation.company), default: []]
                    .append((conversation, date))
            }
            resumeExchangeConversations = (securityIDs, byCompany, datesBySecurityID)
        }
        guard let index = resumeExchangeConversations else { return job.stage == .resumeSent }
        let routeMatches = job.securityID?.appStoreNonempty.map {
            index.securityIDs[job.accountID]?.contains($0) == true
        } ?? false
        // securityID 属于单次请求，岗位与聊天返回值可能不同。
        let matching = (index.byCompany[job.accountID]?[normalizedJobIdentity(job.company)] ?? []).filter {
            conversationMatchesJob($0.conversation, job: job)
        }
        let routeDate = job.securityID.flatMap { index.datesBySecurityID[job.accountID]?[$0] }
        let date = (matching.compactMap(\.sentAt) + [routeDate].compactMap { $0 }).max()
        let exchanged = job.stage == .resumeSent || routeMatches || !matching.isEmpty
        resumeExchangeJobs[job.id] = (job, exchanged, date)
        return exchanged
    }

    func resumeExchangeDate(for job: JobListing) -> Date? {
        _ = hasResumeExchange(for: job)
        return resumeExchangeJobs[job.id]?.sentAt
    }

    private func conversationMatchesJob(_ conversation: Conversation, job: JobListing) -> Bool {
        let title = normalizedJobIdentity(job.title)
        let company = normalizedJobIdentity(job.company)
        guard !title.isEmpty, !company.isEmpty,
              title == normalizedJobIdentity(conversation.jobTitle),
              company == normalizedJobIdentity(conversation.company) else { return false }

        let jobRecruiter = job.recruiterName?.appStoreNonempty.map(normalizedJobIdentity)
        let conversationRecruiter = conversation.recruiterName.appStoreNonempty.map(normalizedJobIdentity)
        if let jobRecruiter, let conversationRecruiter {
            return jobRecruiter == conversationRecruiter
        }
        return true
    }

    private func normalizedJobIdentity(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined()
    }

    func remoteResumeBinding(
        accountID: UUID,
        attachmentSHA256: String
    ) -> BossRemoteResumeBinding? {
        guard let remoteIdentityID = snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.appStoreNonempty,
        let attachmentSHA256 = ResumeDeliveryDigestPolicy.normalizedAttachmentSHA256(
            attachmentSHA256
        ) else { return nil }
        let bindingID = BossRemoteResumeBinding.identifier(
            remoteIdentityID: remoteIdentityID,
            attachmentSHA256: attachmentSHA256
        )
        return snapshot.remoteResumeBindings.first { $0.id == bindingID && $0.accountID == accountID }
    }

    func historyRouteRotationState(accountID: UUID) -> BossHistoryRouteRotationState? {
        guard let remoteIdentityID = snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.appStoreNonempty else { return nil }
        return snapshot.historyRouteRotationStates.first {
            $0.accountID == accountID && $0.remoteIdentityID == remoteIdentityID
        }
    }

    func saveHistoryRouteRotationState(
        accountID: UUID,
        unresolvedOffset: Int,
        regularOffset: Int,
        now: Date = Date()
    ) {
        guard let remoteIdentityID = snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.appStoreNonempty else { return }
        let state = BossHistoryRouteRotationState(
            accountID: accountID,
            remoteIdentityID: remoteIdentityID,
            unresolvedOffset: max(0, unresolvedOffset),
            regularOffset: max(0, regularOffset),
            updatedAt: now
        )
        if let index = snapshot.historyRouteRotationStates.firstIndex(where: { $0.id == state.id }) {
            snapshot.historyRouteRotationStates[index] = state
        } else {
            snapshot.historyRouteRotationStates.append(state)
        }
        scheduleSave()
    }

    func historyConversationSyncState(
        accountID: UUID,
        conversationID: String
    ) -> BossHistoryConversationSyncState? {
        guard let remoteIdentityID = snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.appStoreNonempty else { return nil }
        return snapshot.historyConversationSyncStates.first {
            $0.accountID == accountID &&
                $0.remoteIdentityID == remoteIdentityID &&
                $0.conversationID == conversationID
        }
    }

    func saveHistoryConversationSyncState(_ state: BossHistoryConversationSyncState) {
        guard snapshot.accounts.contains(where: {
            $0.id == state.accountID &&
                $0.status == .active &&
                $0.remoteProfile?.remoteID.appStoreNonempty == state.remoteIdentityID
        }), snapshot.conversations.contains(where: {
            $0.id == state.conversationID && $0.accountID == state.accountID
        }) else { return }
        var state = state
        state.latestHeadMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.latestHeadMID)
        state.gapCursorMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.gapCursorMID)
        state.gapTargetMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.gapTargetMID)
        state.gapNewHeadMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.gapNewHeadMID)
        state.backfillCursorMID = ResumeDeliveryDigestPolicy.normalizedRemoteMID(state.backfillCursorMID)
        if state.gapCursorMID == nil || state.gapNextPage < 2 {
            state.gapCursorMID = nil
            state.gapTargetMID = nil
            state.gapNewHeadMID = nil
            state.gapNextPage = 1
        }
        if state.backfillCursorMID == nil || state.backfillNextPage < 2 {
            state.backfillCursorMID = nil
            state.backfillNextPage = 1
        }
        if let index = snapshot.historyConversationSyncStates.firstIndex(where: { $0.id == state.id }) {
            snapshot.historyConversationSyncStates[index] = state
        } else {
            snapshot.historyConversationSyncStates.append(state)
        }
        scheduleSave()
    }

    /// 仅保存不透明附件令牌，不将请求、Cookie 或响应原文复制到快照。
    @discardableResult
    func saveRemoteResumeBinding(
        _ binding: BossRemoteResumeBinding
    ) throws -> BossRemoteResumeBinding {
        try persistResumeDeliveryMutation {
            let remoteIdentityID = binding.remoteIdentityID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard snapshot.accounts.contains(where: {
                $0.id == binding.accountID &&
                    $0.status == .active &&
                    $0.remoteProfile?.remoteID.appStoreNonempty == remoteIdentityID
            }),
            let attachmentSHA256 = ResumeDeliveryDigestPolicy.normalizedAttachmentSHA256(
                binding.attachmentSHA256
            ) else {
                throw ResumeDeliveryStoreError.invalidRemoteResumeBinding
            }
            let remoteResumeToken = binding.remoteResumeToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteResumeToken.isEmpty, remoteResumeToken.count <= 4_096 else {
                throw ResumeDeliveryStoreError.invalidRemoteResumeBinding
            }

            var normalized = binding
            normalized.remoteIdentityID = remoteIdentityID
            normalized.attachmentSHA256 = attachmentSHA256
            normalized.remoteResumeToken = remoteResumeToken
            normalized.remoteDisplayName = binding.remoteDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appStoreNonempty
                .map { String($0.prefix(255)) }
            if let index = snapshot.remoteResumeBindings.firstIndex(where: { $0.id == normalized.id }) {
                snapshot.remoteResumeBindings[index] = normalized
            } else {
                snapshot.remoteResumeBindings.append(normalized)
            }
            return normalized
        }
    }

    /// 每次转移同步落盘；提交前须保存账号、身份与附件绑定，终态和结果未知状态不能退回写入态。
    @discardableResult
    func transitionResumeDelivery(
        recordID: String,
        to nextState: ResumeDeliveryState,
        remoteResumeToken: String? = nil,
        writeBaselineRemoteMID: String? = nil,
        failureCode: ResumeDeliveryFailureCode? = nil,
        now: Date = Date()
    ) throws -> ResumeDeliveryRecord {
        try persistResumeDeliveryMutation {
            guard let index = snapshot.resumeDeliveryRecords.firstIndex(where: { $0.id == recordID }) else {
                throw ResumeDeliveryStoreError.recordMissing
            }
            var record = snapshot.resumeDeliveryRecords[index]
            guard record.state.canTransition(to: nextState) else {
                throw ResumeDeliveryStoreError.invalidTransition(from: record.state, to: nextState)
            }
            guard snapshot.accounts.contains(where: {
                $0.id == record.accountID &&
                    $0.status == .active &&
                    $0.remoteProfile?.remoteID.appStoreNonempty == record.remoteIdentityID
            }) else {
                throw ResumeDeliveryStoreError.accountIdentityMismatch
            }

            switch nextState {
            case .failed:
                guard let failureCode else { throw ResumeDeliveryStoreError.failureCodeRequired }
                record.failureCode = failureCode
            case .cancelled:
                guard failureCode == nil || failureCode == .cancelled else {
                    throw ResumeDeliveryStoreError.unexpectedFailureCode
                }
                record.failureCode = .cancelled
            default:
                guard failureCode == nil else { throw ResumeDeliveryStoreError.unexpectedFailureCode }
                record.failureCode = nil
            }

            let suppliedToken = remoteResumeToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appStoreNonempty
            let persistedToken = record.remoteResumeToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .appStoreNonempty
            if nextState.requiresRemoteResumeBinding {
                guard let resolvedToken = suppliedToken ?? persistedToken,
                      resolvedToken.count <= 4_096,
                      snapshot.remoteResumeBindings.contains(where: { binding in
                        binding.accountID == record.accountID &&
                            binding.remoteIdentityID == record.remoteIdentityID &&
                            binding.attachmentSHA256 == record.attachmentSHA256 &&
                            binding.remoteResumeToken == resolvedToken
                      }) else {
                    throw ResumeDeliveryStoreError.remoteResumeBindingMissing
                }
                record.remoteResumeToken = resolvedToken
            } else if suppliedToken != nil {
                throw ResumeDeliveryStoreError.invalidRemoteResumeBinding
            }

            record.state = nextState
            record.updatedAt = now
            switch nextState {
            case .dispatching:
                record.writeStartedAt = now
                record.writeBaselineRemoteMID = try normalizedResumeWriteBaselineMID(
                    writeBaselineRemoteMID
                )
            case .requestCreatedAwaitingRecruiter, .serverAcceptedUnverified:
                record.serverAcceptedAt = record.serverAcceptedAt ?? now
            case .confirmed:
                record.serverAcceptedAt = record.serverAcceptedAt ?? now
                record.verifiedAt = now
            default:
                break
            }
            snapshot.resumeDeliveryRecords[index] = record
            return record
        }
    }

    private func normalizedResumeWriteBaselineMID(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 32,
              normalized.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            throw ResumeDeliveryStoreError.invalidNativePromotion
        }
        return normalized
    }

    func upsertJobs(_ jobs: [JobListing]) {
        guard !jobs.isEmpty else { return }
        var updated = snapshot
        var localIndices: [String: Set<Int>] = [:]
        var remoteIndices: [UUID: [String: Set<Int>]] = [:]
        for (index, job) in updated.jobs.enumerated() {
            localIndices[job.id, default: []].insert(index)
            if let remoteID = job.remoteJobID {
                remoteIndices[job.accountID, default: [:]][remoteID, default: []].insert(index)
            }
        }
        for var job in jobs {
            if let remoteJobID = job.remoteJobID?.appStoreNonempty,
               let attempt = automaticGreetingAttempt(accountID: job.accountID, remoteJobID: remoteJobID) {
                job.stage = attempt.succeededAt == nil ? .greetingDrafted : .contacted
            } else if let remoteJobID = job.remoteJobID?.appStoreNonempty,
                      hasAutomaticGreetingAttempt(accountID: job.accountID, remoteJobID: remoteJobID) {
                job.stage = .greetingDrafted
            }
            let remoteJobID = job.remoteJobID?.appStoreNonempty
            let localIndex = localIndices[job.id]?.min()
            let remoteIndex = remoteJobID.flatMap { remoteIndices[job.accountID]?[$0]?.min() }
            // 旧记录 ID 重复时保持首条匹配行为。
            let index = [localIndex, remoteIndex].compactMap { $0 }.min()
            if let index {
                let previous = updated.jobs[index]
                localIndices[previous.id]?.remove(index)
                if let remoteID = previous.remoteJobID {
                    remoteIndices[previous.accountID]?[remoteID]?.remove(index)
                }
                if !job.hasCachedDetail, previous.hasCachedDetail {
                    job.description = previous.description
                    job.detailFetchedAt = previous.detailFetchedAt
                    job.recruiterName = job.recruiterName ?? previous.recruiterName
                    job.recruiterTitle = job.recruiterTitle ?? previous.recruiterTitle
                    job.industry = job.industry ?? previous.industry
                    job.companySize = job.companySize ?? previous.companySize
                    job.financingStage = job.financingStage ?? previous.financingStage
                    job.tags = job.tags ?? previous.tags
                    job.benefits = job.benefits ?? previous.benefits
                }
                if previous.id != job.id {
                    for actionIndex in updated.pendingActions.indices
                    where updated.pendingActions[actionIndex].accountID == job.accountID && updated.pendingActions[actionIndex].jobID == previous.id {
                        updated.pendingActions[actionIndex].jobID = job.id
                    }
                    if selectedJobID == previous.id { selectedJobID = job.id }
                }
                if previous.evidenceText == job.evidenceText {
                    job.assessment = previous.assessment
                    job.stage = previous.stage
                } else {
                    job.assessment = nil
                    job.stage = invalidatedStage(from: previous.stage)
                    updated.pendingActions.removeAll {
                        $0.jobID == job.id && $0.kind == .sendGreeting && $0.status.requiresAttention
                    }
                }
                updated.jobs[index] = job
            } else {
                updated.jobs.append(job)
            }
            let savedIndex = index ?? (updated.jobs.count - 1)
            localIndices[job.id, default: []].insert(savedIndex)
            if let remoteID = job.remoteJobID {
                remoteIndices[job.accountID, default: [:]][remoteID, default: []].insert(savedIndex)
            }
        }
        updated.jobs.sort { $0.capturedAt > $1.capturedAt }
        snapshot = updated
        if let first = jobs.first,
           selectedAccountID == nil || selectedAccountID == first.accountID {
            selectedJobID = first.id
        }
        scheduleSave()
    }

    func markAccountSynced(accountID: UUID) {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        snapshot.accounts[index].lastSyncAt = Date()
        scheduleSave()
    }

    @discardableResult
    func assessJobLocally(id: String) -> JobAssessment? {
        guard snapshot.automation.allowsDrafting else { return nil }
        guard let index = snapshot.jobs.firstIndex(where: { $0.id == id }) else { return nil }
        guard snapshot.jobs[index].hasAuthoritativeDescription else {
            snapshot.jobs[index].assessment = nil
            if snapshot.jobs[index].stage == .recommended || snapshot.jobs[index].stage == .rejected {
                snapshot.jobs[index].stage = .discovered
            }
            snapshot.pendingActions.removeAll {
                $0.jobID == id && $0.kind == .sendGreeting && $0.status.requiresAttention
            }
            scheduleSave()
            return nil
        }
        let assessment = JobMatchingPolicy.assess(
            job: snapshot.jobs[index],
            resume: snapshot.resume,
            preferences: snapshot.preferences
        )
        snapshot.jobs[index].assessment = assessment
        snapshot.jobs[index].stage = assessedStage(
            from: snapshot.jobs[index].stage,
            passesQualityGate: assessment.passesQualityGate(minimumScore: snapshot.preferences.minimumMatchScore)
        )
        scheduleSave()
        return assessment
    }

    /// 在后台补评已缓存的权威详情，使开聊队列不依赖下一轮远端检索。
    @discardableResult
    func assessPendingJobsLocally(accountID: UUID, limit: Int? = nil) async -> Int {
        guard snapshot.automation.allowsDrafting,
              snapshot.automation.automaticallyAssessJobs, !Task.isCancelled else { return 0 }
        let jobs = snapshot.jobs
        let resume = snapshot.resume
        let preferences = snapshot.preferences
        let account = snapshot.accounts.first { $0.id == accountID }
        let evaluation = Task.detached(priority: .userInitiated) {
            let requiredTerms = Set(JobSearchPlanningPolicy.explicitRequiredTerms(in: preferences.requirementText))
            var results: [(job: JobListing, assessment: JobAssessment)] = []
            let count = max(0, limit ?? Int.max)
            for job in jobs {
                guard !Task.isCancelled, results.count < count else { break }
                guard job.accountID == accountID, job.hasAuthoritativeDescription else { continue }
                let staleRequiredTerm = job.stage == .rejected && job.assessment?.provider == "本地规则" &&
                    job.assessment?.risks.contains(where: { risk in
                        guard risk.hasPrefix("缺少必需关键词：") else { return false }
                        return risk.dropFirst("缺少必需关键词：".count).components(separatedBy: "、")
                            .contains { !requiredTerms.contains($0) }
                    }) == true
                guard (job.stage == .discovered && job.assessment == nil) || staleRequiredTerm else { continue }
                results.append((job, JobMatchingPolicy.assess(job: job, resume: resume, preferences: preferences)))
            }
            return results
        }
        let results = await withTaskCancellationHandler {
            await evaluation.value
        } onCancel: { evaluation.cancel() }
        let currentAccount = snapshot.accounts.first { $0.id == accountID }
        guard !Task.isCancelled, snapshot.automation.allowsDrafting,
              snapshot.automation.automaticallyAssessJobs,
              snapshot.resume == resume, snapshot.preferences == preferences,
              currentAccount?.status == account?.status,
              currentAccount?.webProfileID == account?.webProfileID,
              currentAccount?.remoteProfile?.remoteID == account?.remoteProfile?.remoteID else { return 0 }
        let byID = results.reduce(into: [String: (job: JobListing, assessment: JobAssessment)]()) {
            if $0[$1.job.id] == nil { $0[$1.job.id] = $1 }
        }
        var updated = snapshot
        var applied = 0
        for index in updated.jobs.indices {
            guard let result = byID[updated.jobs[index].id], updated.jobs[index] == result.job else { continue }
            updated.jobs[index].assessment = result.assessment
            updated.jobs[index].stage = assessedStage(from: result.job.stage,
                passesQualityGate: result.assessment.passesQualityGate(minimumScore: preferences.minimumMatchScore))
            applied += 1
        }
        if applied > 0 {
            snapshot = updated
            scheduleSave()
        }
        return applied
    }

    func applyCodexAssessment(_ assessment: JobAssessment, to jobID: String) {
        guard snapshot.automation.allowsDrafting else { return }
        guard let index = snapshot.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard snapshot.jobs[index].hasAuthoritativeDescription else {
            snapshot.jobs[index].assessment = nil
            if snapshot.jobs[index].stage == .recommended || snapshot.jobs[index].stage == .rejected {
                snapshot.jobs[index].stage = .discovered
            }
            scheduleSave()
            return
        }
        let hardFailures = JobMatchingPolicy.hardGateFailures(job: snapshot.jobs[index], preferences: snapshot.preferences)
        var finalAssessment = assessment
        if !hardFailures.isEmpty {
            finalAssessment.recommendation = "不建议"
            finalAssessment.greeting = ""
            finalAssessment.risks = Array((hardFailures + finalAssessment.risks).prefix(6))
        }
        snapshot.jobs[index].assessment = finalAssessment
        snapshot.jobs[index].stage = assessedStage(
            from: snapshot.jobs[index].stage,
            passesQualityGate: finalAssessment.passesQualityGate(minimumScore: snapshot.preferences.minimumMatchScore)
        )
        addActivity(accountID: snapshot.jobs[index].accountID, level: .success, title: "Codex 岗位评估完成", detail: "\(snapshot.jobs[index].title)：\(finalAssessment.score) 分，已执行本地硬条件复核。")
        scheduleSave()
    }

    func removeJob(id: String) { removeJobs(ids: [id]) }

    func removeJobs(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var updated = snapshot
        updated.jobs.removeAll { ids.contains($0.id) }
        updated.pendingActions.removeAll { $0.jobID.map(ids.contains) == true }
        snapshot = updated
        if selectedJobID.map(ids.contains) == true { selectedJobID = nil }
        scheduleSave()
    }

    func setJobStage(id: String, stage: JobStage) {
        guard let index = snapshot.jobs.firstIndex(where: { $0.id == id }) else { return }
        snapshot.jobs[index].stage = stage
        scheduleSave()
    }

    func recordAutomaticGreeting(
        jobID: String,
        confirmedMessageID: String,
        deliveredAt: Date
    ) {
        let normalizedMessageID = confirmedMessageID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedMessageID.isEmpty else { return }
        guard let index = snapshot.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard snapshot.jobs[index].hasAuthoritativeDescription else { return }
        snapshot.jobs[index].stage = .contacted
        let job = snapshot.jobs[index]
        if let remoteJobID = job.remoteJobID?.appStoreNonempty,
           let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
            .remoteProfile?.remoteID.appStoreNonempty {
            let attemptID = AutomaticGreetingAttempt.identifier(
                remoteIdentityID: remoteIdentityID,
                remoteJobID: remoteJobID
            )
            if let attemptIndex = snapshot.automaticGreetingAttempts.firstIndex(where: { $0.id == attemptID }) {
                snapshot.automaticGreetingAttempts[attemptIndex].succeededAt = deliveredAt
                snapshot.automaticGreetingAttempts[attemptIndex].confirmedMessageID = normalizedMessageID
            }
        }
        appendActivity(
            accountID: job.accountID,
            level: .success,
            title: "已自动打招呼",
            detail: "\(job.title) · \(job.company)。BOSS 完整消息历史已回读服务端 MID。"
        )
        scheduleSave()
    }

    func markAutomaticGreetingWriteStarted(jobID: String, at date: Date = Date()) throws {
        guard !persistenceBlocked, !isEditingRequirements,
              let job = snapshot.jobs.first(where: { $0.id == jobID }),
              JobMatchingPolicy.hardGateFailures(job: job, preferences: snapshot.preferences).isEmpty,
              let remoteJobID = job.remoteJobID?.appStoreNonempty,
              let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
                .remoteProfile?.remoteID.appStoreNonempty else {
            throw BossAutomationError.operationNotReady
        }
        let attemptID = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        guard let attemptIndex = snapshot.automaticGreetingAttempts.firstIndex(where: {
            $0.id == attemptID
        }), snapshot.automaticGreetingAttempts[attemptIndex].deliveryWriteStartedAt == nil else {
            throw BossAutomationError.operationNotReady
        }
        snapshot.automaticGreetingAttempts[attemptIndex].deliveryWriteStartedAt = date
        saveTask?.cancel()
        saveTask = nil
        try persistence.save(snapshot)
    }

    /// 仅在 BOSS 明确拒绝且尚未外发时释放许可；提交后只能通过权威历史核对恢复。
    func releaseAutomaticGreetingReservationAfterDefinitiveRejection(jobID: String) throws {
        guard !persistenceBlocked,
              let jobIndex = snapshot.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw BossAutomationError.operationNotReady
        }
        let job = snapshot.jobs[jobIndex]
        guard job.stage == .greetingDrafted,
              let remoteJobID = job.remoteJobID?.appStoreNonempty,
              let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
                .remoteProfile?.remoteID.appStoreNonempty else {
            throw BossAutomationError.operationNotReady
        }
        let attemptID = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        guard let attempt = snapshot.automaticGreetingAttempts.first(where: { $0.id == attemptID }),
              attempt.deliveryWriteStartedAt == nil,
              attempt.succeededAt == nil,
              attempt.confirmedMessageID?.appStoreNonempty == nil else {
            throw BossAutomationError.operationNotReady
        }

        let previousSnapshot = snapshot
        snapshot.automaticGreetingAttempts.removeAll { $0.id == attemptID }
        snapshot.automaticGreetingSafetyRecords.removeAll { $0.id == attemptID }
        snapshot.jobs[jobIndex].stage = .recommended
        saveTask?.cancel()
        saveTask = nil
        do {
            try persistence.save(snapshot)
        } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    func reopenAutomaticGreetingForDelivery(jobID: String) throws {
        guard !persistenceBlocked,
              let jobIndex = snapshot.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw BossAutomationError.operationNotReady
        }
        let job = snapshot.jobs[jobIndex]
        guard let remoteJobID = job.remoteJobID?.appStoreNonempty,
              let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
                .remoteProfile?.remoteID.appStoreNonempty else {
            throw BossAutomationError.operationNotReady
        }
        let attemptID = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        guard let attemptIndex = snapshot.automaticGreetingAttempts.firstIndex(where: {
            $0.id == attemptID
        }), snapshot.automaticGreetingAttempts[attemptIndex].deliveryWriteStartedAt == nil else {
            throw BossAutomationError.operationNotReady
        }
        snapshot.automaticGreetingAttempts[attemptIndex].succeededAt = nil
        snapshot.automaticGreetingAttempts[attemptIndex].confirmedMessageID = nil
        snapshot.jobs[jobIndex].stage = .greetingDrafted
        snapshot.activity.removeAll {
            $0.accountID == job.accountID &&
            $0.title == "已自动打招呼" &&
            $0.detail.contains(job.title) &&
            $0.detail.contains(job.company)
        }
        saveTask?.cancel()
        saveTask = nil
        try persistence.save(snapshot)
    }

    /// 仅在完整历史确认未发出对应消息后清除提交边界，与普通错误重试严格分离。
    func reopenAutomaticGreetingAfterAuthoritativeAbsence(jobID: String) throws {
        guard !persistenceBlocked,
              let jobIndex = snapshot.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw BossAutomationError.operationNotReady
        }
        let job = snapshot.jobs[jobIndex]
        guard let remoteJobID = job.remoteJobID?.appStoreNonempty,
              let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
                .remoteProfile?.remoteID.appStoreNonempty else {
            throw BossAutomationError.operationNotReady
        }
        let attemptID = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        guard let attemptIndex = snapshot.automaticGreetingAttempts.firstIndex(where: {
            $0.id == attemptID
        }), snapshot.automaticGreetingAttempts[attemptIndex].deliveryWriteStartedAt != nil,
           snapshot.automaticGreetingAttempts[attemptIndex].confirmedMessageID?.appStoreNonempty == nil,
           snapshot.automaticGreetingAttempts[attemptIndex].succeededAt == nil else {
            throw BossAutomationError.operationNotReady
        }

        let previousSnapshot = snapshot
        snapshot.automaticGreetingAttempts[attemptIndex].deliveryWriteStartedAt = nil
        snapshot.jobs[jobIndex].stage = .greetingDrafted
        saveTask?.cancel()
        saveTask = nil
        do {
            try persistence.save(snapshot)
        } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    func prepareAutomaticGreeting(jobID: String, now: Date = Date()) throws {
        guard !persistenceBlocked, !isEditingRequirements,
              let index = snapshot.jobs.firstIndex(where: { $0.id == jobID }),
              snapshot.jobs[index].stage == .recommended else {
            throw BossAutomationError.operationNotReady
        }
        let job = snapshot.jobs[index]
        guard JobMatchingPolicy.hardGateFailures(
            job: job,
            preferences: snapshot.preferences
        ).isEmpty else {
            throw BossAutomationError.operationNotReady
        }
        guard automaticGreetingCountToday(accountID: job.accountID, now: now) < snapshot.automation.dailyGreetingLimit else {
            throw BossAutomationError.operationNotReady
        }
        if let nextAllowedAt = nextAutomaticGreetingAllowedAt(
            accountID: job.accountID,
            intervalSeconds: snapshot.automation.greetingIntervalSeconds
        ), nextAllowedAt > now {
            throw BossAutomationError.operationNotReady
        }
        guard let remoteJobID = job.remoteJobID?.appStoreNonempty,
              let remoteIdentityID = snapshot.accounts.first(where: { $0.id == job.accountID })?
                .remoteProfile?.remoteID.appStoreNonempty else {
            throw BossAutomationError.operationNotReady
        }
        let attempt = AutomaticGreetingAttempt(
            accountID: job.accountID,
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID,
            attemptedAt: now
        )
        let safetyRecord = AutomaticGreetingSafetyRecord(attempt: attempt)
        guard !snapshot.automaticGreetingAttempts.contains(where: { $0.id == attempt.id }),
              !snapshot.automaticGreetingSafetyRecords.contains(where: { $0.id == safetyRecord.id }),
              !snapshot.dailyCommunicationRecords.contains(where: { $0.id == safetyRecord.id }) else {
            throw BossAutomationError.operationNotReady
        }
        snapshot.automaticGreetingAttempts.append(attempt)
        snapshot.automaticGreetingSafetyRecords.append(safetyRecord)
        snapshot.jobs[index].stage = .greetingDrafted
        appendActivity(
            accountID: job.accountID,
            level: .info,
            title: "自动打招呼已尝试",
            detail: "\(job.title) · \(job.company)。尝试记录已先持久化；即使响应超时也不会自动重试。"
        )
        saveTask?.cancel()
        saveTask = nil
        try persistence.save(snapshot)
    }

    func automaticGreetingCountToday(accountID: UUID, now: Date = Date()) -> Int {
        guard let remoteIdentityID = snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.appStoreNonempty else { return 0 }
        let identityFingerprint = AutomaticGreetingSafetyRecord.identityFingerprint(
            remoteIdentityID: remoteIdentityID
        )
        let start = Calendar.current.startOfDay(for: now)
        return Set((snapshot.automaticGreetingSafetyRecords + snapshot.dailyCommunicationRecords).filter {
            $0.identityFingerprint == identityFingerprint &&
            $0.attemptedAt >= start &&
            $0.attemptedAt <= now
        }.map(\.id)).count
    }

    func usedDailyGreetingQuotaToday(accountID: UUID, now: Date = Date()) -> Int {
        // 互动记录可能超过上限；此处统计占用额度，不等于发送成功数。
        min(snapshot.automation.dailyGreetingLimit, automaticGreetingCountToday(accountID: accountID, now: now))
    }

    func recordDailyCommunications(_ records: [AutomaticGreetingSafetyRecord], now: Date = Date()) {
        let start = Calendar.current.startOfDay(for: now)
        var byID = Dictionary(snapshot.dailyCommunicationRecords.filter {
            $0.attemptedAt >= start && $0.attemptedAt <= now
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where record.attemptedAt >= start && record.attemptedAt <= now {
            byID[record.id] = record
        }
        snapshot.dailyCommunicationRecords = byID.values.sorted { $0.id < $1.id }
        scheduleSave()
    }

    func dailyCommunicationLastSyncedAt(accountID: UUID, now: Date = Date()) -> Date? {
        guard let identity = snapshot.accounts.first(where: { $0.id == accountID })?.remoteProfile?.remoteID,
              let date = snapshot.dailyCommunicationSyncedAt[AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: identity)],
              date >= Calendar.current.startOfDay(for: now), date <= now else { return nil }
        return date
    }

    func completeDailyCommunicationSync(remoteIdentityID: String, startedAt: Date) {
        snapshot.dailyCommunicationSyncedAt[AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: remoteIdentityID)] = startedAt
        flush()
    }

    func communicationCountToday(accountID: UUID? = nil, now: Date = Date()) -> Int {
        let identity = accountID.flatMap { id in
            snapshot.accounts.first { $0.id == id }?.remoteProfile?.remoteID.appStoreNonempty
        }
        guard accountID == nil || identity != nil else { return 0 }
        let fingerprint = identity.map { AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: $0) }
        let identities = Set(statisticsAccounts.compactMap { $0.remoteProfile?.remoteID.appStoreNonempty })
        let fingerprints = Set(identities.map { AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: $0) })
        let start = Calendar.current.startOfDay(for: now)
        let records = snapshot.dailyCommunicationRecords.filter {
            (fingerprint != nil ? $0.identityFingerprint == fingerprint : fingerprints.contains($0.identityFingerprint)) &&
            $0.attemptedAt >= start && $0.attemptedAt <= now
        }
        let confirmed = snapshot.automaticGreetingAttempts.filter {
            (identity != nil ? $0.remoteIdentityID == identity : identities.contains($0.remoteIdentityID)) &&
            $0.succeededAt.map { $0 >= start && $0 <= now } == true && $0.confirmedMessageID?.appStoreNonempty != nil
        }
        return Set(records.map(\.id) + confirmed.map(\.id)).count
    }

    func confirmedAutomaticGreetingCountToday(accountID: UUID, now: Date = Date()) -> Int {
        guard let remoteIdentityID = snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.appStoreNonempty else { return 0 }
        let start = Calendar.current.startOfDay(for: now)
        return snapshot.automaticGreetingAttempts.filter {
            $0.remoteIdentityID == remoteIdentityID &&
            $0.succeededAt.map { $0 >= start && $0 <= now } == true &&
            $0.confirmedMessageID?.appStoreNonempty != nil
        }.count
    }

    func confirmedAutomaticGreetingCountToday(now: Date = Date()) -> Int {
        let identities = Set(statisticsAccounts.compactMap { $0.remoteProfile?.remoteID.appStoreNonempty })
        let start = Calendar.current.startOfDay(for: now)
        return snapshot.automaticGreetingAttempts.filter {
            identities.contains($0.remoteIdentityID) &&
            $0.succeededAt.map { $0 >= start && $0 <= now } == true &&
            $0.confirmedMessageID?.appStoreNonempty != nil
        }.count
    }

    func totalDailyGreetingLimit() -> Int {
        statisticsAccounts.count * snapshot.automation.dailyGreetingLimit
    }

    func dailyResumeExchangeLastSyncedAt(accountID: UUID, now: Date = Date()) -> Date? {
        guard let identity = snapshot.accounts.first(where: { $0.id == accountID })?.remoteProfile?.remoteID,
              let date = snapshot.dailyResumeExchangeSyncedAt[AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: identity)],
              date >= Calendar.current.startOfDay(for: now), date <= now else { return nil }
        return date
    }

    func recordDailyResumeExchanges(_ records: [AutomaticGreetingSafetyRecord], now: Date = Date()) {
        let start = Calendar.current.startOfDay(for: now)
        var byID = Dictionary(snapshot.dailyResumeExchangeRecords.filter {
            $0.attemptedAt >= start && $0.attemptedAt <= now
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where record.attemptedAt >= start && record.attemptedAt <= now {
            byID[record.id] = record
        }
        snapshot.dailyResumeExchangeRecords = byID.values.sorted { $0.id < $1.id }
        scheduleSave()
    }

    func completeDailyResumeExchangeSync(remoteIdentityID: String, startedAt: Date) {
        snapshot.dailyResumeExchangeSyncedAt[AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: remoteIdentityID)] = startedAt
        flush()
    }

    func resumeExchangeCountToday(accountID: UUID? = nil, now: Date = Date()) -> Int {
        let identity = accountID.flatMap { id in
            snapshot.accounts.first { $0.id == id }?.remoteProfile?.remoteID.appStoreNonempty
        }
        guard accountID == nil || identity != nil else { return 0 }
        let fingerprint = identity.map { AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: $0) }
        let identities = Set(statisticsAccounts.compactMap { $0.remoteProfile?.remoteID.appStoreNonempty })
        let fingerprints = Set(identities.map { AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: $0) })
        let start = Calendar.current.startOfDay(for: now)
        let syncedIdentities = Set(snapshot.dailyResumeExchangeSyncedAt.filter {
            $0.value >= start && $0.value <= now
        }.keys)
        let official = snapshot.dailyResumeExchangeRecords.filter {
            (fingerprint != nil ? $0.identityFingerprint == fingerprint : fingerprints.contains($0.identityFingerprint)) &&
            syncedIdentities.contains($0.identityFingerprint) && $0.attemptedAt >= start && $0.attemptedAt <= now
        }
        var exchanges = Set(official.map(\.id))
        let officialRecipients = Set(official.compactMap(\.recipientFingerprint))
        let toolRecords = snapshot.resumeDeliveryRecords.filter { record in
            guard identity != nil ? record.remoteIdentityID == identity : identities.contains(record.remoteIdentityID),
                  let date = record.resumeExchangeAt, date >= start, date <= now else { return false }
            // 已同步部分由官方列表覆盖，后续发送仍须立即补计。
            let syncedAt = snapshot.dailyResumeExchangeSyncedAt[AutomaticGreetingSafetyRecord.identityFingerprint(remoteIdentityID: record.remoteIdentityID)]
            return date > (syncedAt.flatMap { $0 >= start && $0 <= now ? $0 : nil } ?? .distantPast)
        }
        let accounts = snapshot.accounts.filter {
            $0.remoteProfile?.remoteID.appStoreNonempty.map { identity != nil ? $0 == identity : identities.contains($0) } == true
        }
        let jobsByAccount = Dictionary(grouping: snapshot.jobs, by: \.accountID)
            .mapValues { Dictionary(grouping: $0, by: { normalizedJobIdentity($0.company) }) }
        var matchedToolIDs: Set<String> = []
        for account in accounts {
            guard let remoteIdentityID = account.remoteProfile?.remoteID.appStoreNonempty else { continue }
            let accountTools = toolRecords.filter { $0.remoteIdentityID == remoteIdentityID }
            for conversation in snapshot.conversations where conversation.accountID == account.id {
                let aliases = Set([conversation.id, conversation.remoteConversationID].compactMap { $0 })
                let tools = accountTools.filter { aliases.contains($0.conversationID) }
                guard !tools.isEmpty || conversation.messages.contains(where: {
                    $0.resumeAttachmentSentAt.map { $0 >= start && $0 <= now } == true
                }) else { continue }
                matchedToolIDs.formUnion(tools.map(\.id))
                if let recipient = conversation.encryptedBossID?.appStoreNonempty,
                   officialRecipients.contains(AutomaticGreetingAttempt.identifier(
                    remoteIdentityID: remoteIdentityID, remoteJobID: "recipient:\(recipient)"
                   )) { continue }
                let jobIDs = (jobsByAccount[account.id]?[normalizedJobIdentity(conversation.company)] ?? [])
                    .filter { conversationMatchesJob(conversation, job: $0) }
                    .compactMap { $0.remoteJobID?.appStoreNonempty }
                    .map { AutomaticGreetingAttempt.identifier(remoteIdentityID: remoteIdentityID, remoteJobID: $0) }
                    .sorted()
                // 官方与聊天可能返回不同路由，沿用岗位匹配；同一会话多条凭证只补计一次。
                let key = jobIDs.first(where: { exchanges.contains($0) }) ?? jobIDs.first ??
                    AutomaticGreetingAttempt.identifier(remoteIdentityID: remoteIdentityID, remoteJobID: "conversation:\(conversation.remoteConversationID ?? conversation.id)")
                exchanges.insert(key)
            }
        }
        for record in toolRecords where !matchedToolIDs.contains(record.id) {
            exchanges.insert(AutomaticGreetingAttempt.identifier(
                remoteIdentityID: record.remoteIdentityID, remoteJobID: "conversation:\(record.conversationID)"
            ))
        }
        return exchanges.count
    }

    func nextAutomaticGreetingAllowedAt(accountID: UUID, intervalSeconds: Int) -> Date? {
        guard let remoteIdentityID = snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.appStoreNonempty else { return nil }
        let identityFingerprint = AutomaticGreetingSafetyRecord.identityFingerprint(
            remoteIdentityID: remoteIdentityID
        )
        let perIdentityDate = snapshot.automaticGreetingSafetyRecords
            .filter({ $0.identityFingerprint == identityFingerprint })
            .max(by: { $0.attemptedAt < $1.attemptedAt })
            .map {
                AutomaticGreetingPacingPolicy.nextAllowedAt(
                    after: $0,
                    intervalSeconds: intervalSeconds
                )
            }
        return perIdentityDate
    }

    func hasQueuedAutomaticGreetingCandidate(accountID: UUID) -> Bool {
        queuedAutomaticGreetingCandidateCount(accountID: accountID) > 0
    }

    func queuedAutomaticGreetingCandidateCount(accountID: UUID) -> Int {
        guard !isEditingRequirements else { return 0 }
        return snapshot.jobs.filter { job in
            job.accountID == accountID &&
            job.stage == .recommended &&
            job.hasAuthoritativeDescription &&
            job.securityID?.appStoreNonempty != nil &&
            job.remoteJobID?.appStoreNonempty != nil &&
            job.listID?.appStoreNonempty != nil &&
            !hasAutomaticGreetingAttempt(
                accountID: accountID,
                remoteJobID: job.remoteJobID ?? ""
            ) &&
            JobMatchingPolicy.hardGateFailures(
                job: job,
                preferences: snapshot.preferences
            ).isEmpty
        }.count
    }

    func nextEligibleAutomaticGreetingAccountID(
        accountIDs: [UUID],
        now: Date = Date()
    ) -> UUID? {
        let candidates = accountIDs.filter { accountID in
            guard snapshot.accounts.contains(where: {
                $0.id == accountID && $0.status == .active
            }), automaticGreetingCountToday(accountID: accountID, now: now) < snapshot.automation.dailyGreetingLimit,
               hasQueuedAutomaticGreetingCandidate(accountID: accountID) else { return false }
            guard let nextAllowedAt = nextAutomaticGreetingAllowedAt(
                accountID: accountID,
                intervalSeconds: snapshot.automation.greetingIntervalSeconds
            ) else { return true }
            return nextAllowedAt <= now
        }
        return candidates.min { lhs, rhs in
            let lhsDate = latestAutomaticGreetingAttemptAt(accountID: lhs)
            let rhsDate = latestAutomaticGreetingAttemptAt(accountID: rhs)
            switch (lhsDate, rhsDate) {
            case (nil, nil):
                return lhs.uuidString < rhs.uuidString
            case (nil, _):
                return true
            case (_, nil):
                return false
            case (.some(let lhsDate), .some(let rhsDate)):
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.uuidString < rhs.uuidString
            }
        }
    }

    private func latestAutomaticGreetingAttemptAt(accountID: UUID) -> Date? {
        guard let remoteIdentityID = snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.appStoreNonempty else { return nil }
        let identityFingerprint = AutomaticGreetingSafetyRecord.identityFingerprint(
            remoteIdentityID: remoteIdentityID
        )
        return snapshot.automaticGreetingSafetyRecords
            .filter { $0.identityFingerprint == identityFingerprint }
            .map(\.attemptedAt)
            .max()
    }

    func hasAutomaticGreetingAttempt(accountID: UUID, remoteJobID: String) -> Bool {
        guard let remoteIdentityID = snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.appStoreNonempty else { return false }
        let attemptID = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        if greetingAttemptIDs == nil {
            greetingAttemptIDs = Set((snapshot.automaticGreetingSafetyRecords + snapshot.dailyCommunicationRecords).map(\.id))
                .union(snapshot.automaticGreetingAttempts.map(\.id))
        }
        return greetingAttemptIDs?.contains(attemptID) == true
    }

    private func automaticGreetingAttempt(
        accountID: UUID,
        remoteJobID: String
    ) -> AutomaticGreetingAttempt? {
        guard let remoteIdentityID = snapshot.accounts.first(where: { $0.id == accountID })?
            .remoteProfile?.remoteID.appStoreNonempty else { return nil }
        let attemptID = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        return snapshot.automaticGreetingAttempts.first { $0.id == attemptID }
    }

    @discardableResult
    func upsertBossFriendSummaries(_ summaries: [BossFriendSummary], accountID: UUID) -> Int {
        guard !summaries.isEmpty else { return 0 }
        var updated = snapshot
        var conversationIndices: [String: Set<Int>] = [:]
        for (index, conversation) in updated.conversations.enumerated() where conversation.accountID == accountID {
            conversationIndices[conversation.id, default: []].insert(index)
        }
        var insertedIncomingCount = 0
        for summary in summaries {
            guard let remoteConversationID = summary.conversationID.appStoreNonempty else { continue }
            let scopedConversationID = "boss-\(StableIdentifier.fnv1a64([accountID.uuidString, remoteConversationID].joined(separator: "|")))"
            let direction: MessageDirection = switch summary.latestIsIncoming {
            case .some(true): .incoming
            case .some(false): .outgoing
            case nil: .system
            }
            let remoteMID = summary.latestRemoteMID.appStoreNonempty
            let messageID = remoteMID.map {
                bossHistoryMessageIdentifier(
                    accountID: accountID,
                    remoteConversationID: remoteConversationID,
                    remoteMID: $0
                )
            } ?? "remote-\(StableIdentifier.fnv1a64([accountID.uuidString, remoteConversationID, String(summary.updatedAt.timeIntervalSince1970), summary.latestText].joined(separator: "|")))"
            let latestText = String(summary.latestText.prefix(4_096))
            let decision = direction == .incoming && !latestText.isEmpty
                ? ConversationPolicy.classify(latestText)
                : nil
            let displayDate = summary.updatedAt.timeIntervalSince1970 > 0 ? summary.updatedAt : Date()
            let message: ChatMessage? = latestText.isEmpty && remoteMID == nil ? nil : ChatMessage(
                id: messageID,
                direction: direction,
                text: latestText,
                sentAt: displayDate,
                intent: decision?.intent,
                confidence: decision?.confidence,
                remoteMID: remoteMID,
                remoteSenderID: summary.latestSenderID.appStoreNonempty,
                remoteRecipientID: summary.latestRecipientID.appStoreNonempty,
                remoteMessageType: summary.latestMessageType,
                remoteActionAID: summary.latestActionAID,
                remoteScene: summary.latestScene,
                hasAuthoritativeDirection: summary.latestDirectionIsAuthoritative,
                isAuthoritativeHistoryRecord: false,
                hasAuthoritativeConsentPayload: false
            )

            let conversationIndex = [conversationIndices[scopedConversationID]?.min(),
                                     conversationIndices[remoteConversationID]?.min()].compactMap { $0 }.min()
            if let conversationIndex {
                let previousID = updated.conversations[conversationIndex].id
                if previousID != scopedConversationID {
                    conversationIndices[previousID]?.remove(conversationIndex)
                    conversationIndices[scopedConversationID, default: []].insert(conversationIndex)
                    updated.conversations[conversationIndex].id = scopedConversationID
                    for actionIndex in updated.pendingActions.indices
                    where updated.pendingActions[actionIndex].accountID == accountID && updated.pendingActions[actionIndex].conversationID == previousID {
                        updated.pendingActions[actionIndex].conversationID = scopedConversationID
                    }
                    if selectedConversationID == previousID { selectedConversationID = scopedConversationID }
                }
                let remoteIsStale = updated.conversations[conversationIndex].remoteUpdatedAt.map { summary.updatedAt < $0 } ?? false
                guard !remoteIsStale else { continue }
                if !summary.recruiterName.isEmpty { updated.conversations[conversationIndex].recruiterName = summary.recruiterName }
                if !summary.company.isEmpty { updated.conversations[conversationIndex].company = summary.company }
                if !summary.jobTitle.isEmpty { updated.conversations[conversationIndex].jobTitle = summary.jobTitle }
                if !summary.jobSalary.isEmpty { updated.conversations[conversationIndex].jobSalary = summary.jobSalary }
                if !summary.jobLocation.isEmpty { updated.conversations[conversationIndex].jobLocation = summary.jobLocation }
                updated.conversations[conversationIndex].remoteConversationID = remoteConversationID
                if let securityID = summary.securityID.appStoreNonempty {
                    updated.conversations[conversationIndex].securityID = securityID
                }
                if let listID = summary.listID.appStoreNonempty {
                    updated.conversations[conversationIndex].listID = listID
                }
                if let encryptedBossID = summary.encryptedBossID.appStoreNonempty {
                    updated.conversations[conversationIndex].encryptedBossID = encryptedBossID
                }
                if let friendSource = summary.friendSource.appStoreNonempty {
                    updated.conversations[conversationIndex].friendSource = friendSource
                }
                if let groupID = summary.groupID.appStoreNonempty {
                    updated.conversations[conversationIndex].groupID = groupID
                }
                updated.conversations[conversationIndex].lastSyncedAt = Date()
                updated.conversations[conversationIndex].remoteUpdatedAt = summary.updatedAt
                guard let message else {
                    updated.conversations[conversationIndex].unreadCount = max(0, summary.unreadCount)
                    continue
                }
                guard !updated.conversations[conversationIndex].messages.contains(where: {
                    $0.id == messageID || (remoteMID != nil && $0.remoteMID == remoteMID)
                }) else {
                    updated.conversations[conversationIndex].unreadCount = max(0, summary.unreadCount)
                    continue
                }
                updated.conversations[conversationIndex].messages.append(message)
                updated.conversations[conversationIndex].messages.sort(by: bossMessageSort)
                updated.conversations[conversationIndex].unreadCount = max(0, summary.unreadCount)
                if direction == .incoming { insertedIncomingCount += 1 }
            } else {
                let initialMessages = message.map { [$0] } ?? []
                conversationIndices[scopedConversationID, default: []].insert(updated.conversations.count)
                updated.conversations.append(
                    Conversation(
                        id: scopedConversationID,
                        accountID: accountID,
                        remoteConversationID: remoteConversationID,
                        securityID: summary.securityID.isEmpty ? nil : summary.securityID,
                        listID: summary.listID.isEmpty ? nil : summary.listID,
                        encryptedBossID: summary.encryptedBossID.appStoreNonempty,
                        friendSource: summary.friendSource.appStoreNonempty,
                        groupID: summary.groupID.appStoreNonempty,
                        recruiterName: summary.recruiterName,
                        company: summary.company,
                        jobTitle: summary.jobTitle,
                        messages: initialMessages,
                        unreadCount: max(0, summary.unreadCount),
                        lastSyncedAt: Date(),
                        remoteUpdatedAt: summary.updatedAt,
                        sourceURL: "https://www.zhipin.com/web/geek/chat",
                        jobSalary: summary.jobSalary.appStoreNonempty,
                        jobLocation: summary.jobLocation.appStoreNonempty
                    )
                )
                if message != nil, direction == .incoming { insertedIncomingCount += 1 }
            }
        }
        updated.conversations.sort { $0.lastSyncedAt > $1.lastSyncedAt }
        snapshot = updated
        scheduleSave()
        return insertedIncomingCount
    }

    /// 仅移除无法路由的空占位会话；有历史、待办或投递状态的记录继续保留。
    @discardableResult
    func pruneUnrouteableBossConversationPlaceholders(accountID: UUID) -> Int {
        let protectedConversationIDs = Set(snapshot.pendingActions.compactMap { action -> String? in
            guard action.accountID == accountID, action.status.requiresAttention else { return nil }
            return action.conversationID
        }).union(snapshot.resumeDeliveryRecords.compactMap { record -> String? in
            record.accountID == accountID ? record.conversationID : nil
        })
        let beforeCount = snapshot.conversations.count
        snapshot.conversations.removeAll { conversation in
            guard conversation.accountID == accountID,
                  conversation.messages.isEmpty,
                  !protectedConversationIDs.contains(conversation.id) else { return false }
            let hasGroupRoute = conversation.groupID?.appStoreNonempty != nil
            let hasIndividualRoute = conversation.securityID?.appStoreNonempty != nil &&
                conversation.encryptedBossID?.appStoreNonempty != nil &&
                conversation.friendSource?.appStoreNonempty != nil
            return !hasGroupRoute && !hasIndividualRoute
        }
        let removedCount = beforeCount - snapshot.conversations.count
        guard removedCount > 0 else { return 0 }
        if let selectedConversationID,
           !snapshot.conversations.contains(where: { $0.id == selectedConversationID }) {
            self.selectedConversationID = nil
        }
        scheduleSave()
        return removedCount
    }

    @discardableResult
    func upsertBossHistoryMessages(
        messages: [BossResumeHistoryMessage],
        accountID: UUID,
        conversationID: String,
        authoritativeCurrentUserID: String? = nil
    ) -> BossHistorySyncOutcome {
        guard let remoteIdentityID = snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        })?.remoteProfile?.remoteID.appStoreNonempty,
        let conversationIndex = snapshot.conversations.firstIndex(where: {
            $0.accountID == accountID &&
                ($0.id == conversationID || $0.remoteConversationID == conversationID)
        }) else {
            return .empty(conversationID: conversationID)
        }

        var conversation = snapshot.conversations[conversationIndex]
        let localConversationID = conversation.id
        let remoteConversationID = conversation.remoteConversationID
            ?? localConversationID
        let previousNewestSentAt = conversation.messages.max { $0.sentAt < $1.sentAt }?.sentAt ?? .distantPast
        var outcome = BossHistorySyncOutcome.empty(conversationID: localConversationID)
        var newlyUnreadIncomingCount = 0
        var newestInput: (date: Date, mid: String)?
        var newlyAuthoritativeQuestionMessageIDs = Set<String>()

        for remoteMessage in messages {
            guard let remoteMID = remoteMessage.messageID.appStoreNonempty,
                  remoteMID.count <= 4_096 else {
                outcome.ignoredMessageCount += 1
                continue
            }
            let directionResult = bossAuthoritativeDirection(
                message: remoteMessage,
                currentUserID: authoritativeCurrentUserID?.appStoreNonempty ?? remoteIdentityID
            )
            let text = String((remoteMessage.sanitizedText ?? "").prefix(4_096))
            let decision = directionResult.isAuthoritative && directionResult.direction == .incoming && !text.isEmpty
                ? ConversationPolicy.classify(text)
                : nil
            let remoteDate = bossHistoryDate(milliseconds: remoteMessage.timestampMilliseconds)
            let messageID = bossHistoryMessageIdentifier(
                accountID: accountID,
                remoteConversationID: remoteConversationID,
                remoteMID: remoteMID
            )
            let existingIndex = conversation.messages.firstIndex(where: {
                $0.remoteMID == remoteMID || $0.id == messageID
            })
            let storedDate = remoteDate
                ?? existingIndex.map { conversation.messages[$0].sentAt }
                ?? Date(timeIntervalSince1970: 0)
            var incoming = ChatMessage(
                id: messageID,
                direction: directionResult.direction,
                text: text,
                sentAt: storedDate,
                intent: decision?.intent,
                confidence: decision?.confidence,
                remoteMID: remoteMID,
                remoteSenderID: remoteMessage.senderID?.appStoreNonempty,
                remoteRecipientID: remoteMessage.recipientID?.appStoreNonempty,
                remoteMessageType: remoteMessage.messageType,
                remoteBodyType: remoteMessage.bodyType,
                remoteActionAID: remoteMessage.actionID,
                actionAnnexType: remoteMessage.actionAnnexType,
                remoteScene: remoteMessage.actionScene,
                actionWasOperated: remoteMessage.actionWasOperated,
                dialogType: remoteMessage.dialogType,
                dialogWasOperated: remoteMessage.dialogWasOperated,
                dialogButtonActionAID: remoteMessage.dialogButtonActionAID,
                dialogButtonScene: remoteMessage.dialogButtonScene,
                hyperLinkType: remoteMessage.hyperLinkType,
                hyperLinkResumeToken: remoteMessage.hyperLinkResumeToken,
                hasAuthoritativeDirection: directionResult.isAuthoritative,
                isAuthoritativeHistoryRecord: true,
                hasAuthoritativeConsentPayload: !text.isEmpty ||
                    remoteMessage.actionID != nil ||
                    remoteMessage.dialogButtonActionAID != nil
            )

            if let existingIndex {
                let existing = conversation.messages[existingIndex]
                let existingWasFullHistory = existing.isAuthoritativeHistoryRecord == true
                let existingWasAuthoritativeQuestion = existingWasFullHistory &&
                    existing.hasAuthoritativeDirection == true &&
                    existing.direction == .incoming &&
                    existing.intent == .question
                incoming.text = text.isEmpty ? existing.text : text
                incoming.intent = decision?.intent ?? existing.intent
                incoming.confidence = decision?.confidence ?? existing.confidence
                if !directionResult.isAuthoritative {
                    incoming.direction = existing.direction
                    // 显示方向不能用作授权，每次完整历史刷新须重新证明收发双方归属。
                    incoming.hasAuthoritativeDirection = false
                }
                incoming.remoteSenderID = incoming.remoteSenderID ?? existing.remoteSenderID
                incoming.remoteRecipientID = incoming.remoteRecipientID ?? existing.remoteRecipientID
                incoming.remoteMessageType = incoming.remoteMessageType ?? existing.remoteMessageType
                // 每次历史刷新完整替换同意及附件凭证，缺失字段必须撤销旧证据，不能继承。
                if incoming != existing {
                    conversation.messages[existingIndex] = incoming
                    outcome.refreshedMessageCount += 1
                }
                if !existingWasAuthoritativeQuestion,
                   directionResult.isAuthoritative,
                   directionResult.direction == .incoming,
                   decision?.intent == .question {
                    newlyAuthoritativeQuestionMessageIDs.insert(messageID)
                }
            } else {
                conversation.messages.append(incoming)
                outcome.insertedMessageCount += 1
                if directionResult.isAuthoritative && directionResult.direction == .incoming {
                    outcome.insertedIncomingCount += 1
                    if storedDate > previousNewestSentAt {
                        newlyUnreadIncomingCount += 1
                    }
                    if decision?.intent == .question {
                        newlyAuthoritativeQuestionMessageIDs.insert(messageID)
                    }
                }
            }

            if newestInput == nil || storedDate > newestInput!.date ||
                (storedDate == newestInput!.date && bossMessageIDPrecedes(newestInput!.mid, remoteMID)) {
                newestInput = (storedDate, remoteMID)
            }
        }

        conversation.messages.sort(by: bossMessageSort)
        conversation.lastSyncedAt = Date()
        conversation.unreadCount = max(
            conversation.unreadCount,
            newlyUnreadIncomingCount
        )
        if let newestDate = newestInput?.date,
           newestDate.timeIntervalSince1970 > 0,
           conversation.remoteUpdatedAt.map({ newestDate > $0 }) ?? true {
            conversation.remoteUpdatedAt = newestDate
        }
        outcome.newestRemoteMID = newestInput?.mid

        snapshot.conversations[conversationIndex] = conversation
        let candidateMIDs = Set(messages.compactMap { $0.messageID.appStoreNonempty })
        let candidates = candidateMIDs.isEmpty ? [] : authoritativeResumeConsentCandidates(accountID: accountID, conversationID: localConversationID).filter {
            $0.conversationID == localConversationID && candidateMIDs.contains($0.triggerRemoteMID)
        }
        outcome.authoritativeConsentCount = candidates.count
        if !snapshot.automation.automaticallySendResume {
            for evidence in candidates {
                insertManualResumeActionIfNeeded(evidence: evidence)
            }
        }
        let latestAuthoritativeQuestion = conversation.messages
            .filter { newlyAuthoritativeQuestionMessageIDs.contains($0.id) }
            .max(by: bossMessageSort)
        if snapshot.automation.allowsDrafting,
           snapshot.automation.automaticallyDraftReplies,
           let latestQuestion = latestAuthoritativeQuestion {
            insertQuestionActionIfNeeded(
                message: latestQuestion,
                conversation: conversation
            )
        }
        scheduleSave()
        return outcome
    }

    func authoritativeResumeConsentCandidates(accountID: UUID, conversationID: String? = nil) -> [ResumeConsentEvidence] {
        guard let account = snapshot.accounts.first(where: {
            $0.id == accountID && $0.status == .active
        }), let remoteIdentityID = account.remoteProfile?.remoteID.appStoreNonempty else {
            return []
        }
        let processedConsentIDs = Set(snapshot.resumeDeliveryRecords.map(\.consentIdentifier))
        let safetyRecordIDs = Set(snapshot.resumeConsentSafetyRecords.map(\.id))
        return snapshot.conversations
            .filter {
                $0.accountID == accountID && (conversationID == nil || $0.id == conversationID || $0.remoteConversationID == conversationID)
            }
            .flatMap { conversation in
                conversation.messages.compactMap { message in
                    bossResumeConsentEvidence(
                        message: message,
                        conversation: conversation,
                        remoteIdentityID: remoteIdentityID
                    )
                }
            }
            .filter { evidence in
                let consentID = ResumeDeliveryRecord.consentIdentifier(
                    remoteIdentityID: evidence.remoteIdentityID,
                    conversationID: evidence.conversationID,
                    triggerRemoteMID: evidence.triggerRemoteMID
                )
                let safetyID = ResumeConsentSafetyRecord.identifier(
                    remoteIdentityID: evidence.remoteIdentityID,
                    triggerRemoteMID: evidence.triggerRemoteMID
                )
                guard !processedConsentIDs.contains(consentID),
                      !safetyRecordIDs.contains(safetyID) else {
                    return false
                }
                let blockers = resumeDeliveryBlockers(
                    accountID: evidence.accountID,
                    remoteIdentityID: evidence.remoteIdentityID,
                    conversationID: evidence.conversationID
                )
                if conversationHasAuthoritativeOutgoingResume(
                    accountID: evidence.accountID,
                    conversationID: evidence.conversationID
                ) {
                    return false
                }
                guard !blockers.isEmpty else { return true }
                // 原生卡片仅推进同一条待确认 type-3 投递链，时间关联与唯一性由控制器校验。
                return evidence.exchangeKind == .acceptNativeRequest &&
                    blockers.allSatisfy {
                        $0.exchangeKind == .requestRecruiterConfirmation &&
                            $0.state == .requestCreatedAwaitingRecruiter
                    }
            }
            .sorted {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
                return $0.triggerRemoteMID < $1.triggerRemoteMID
            }
    }

    private func resumeDeliveryAlreadyExists(
        accountID: UUID,
        remoteIdentityID: String,
        conversationID: String
    ) -> Bool {
        conversationHasAuthoritativeOutgoingResume(
            accountID: accountID,
            conversationID: conversationID
        ) || !resumeDeliveryBlockers(
            accountID: accountID,
            remoteIdentityID: remoteIdentityID,
            conversationID: conversationID
        ).isEmpty
    }

    private func resumeDeliveryBlockers(
        accountID: UUID,
        remoteIdentityID: String,
        conversationID: String
    ) -> [ResumeDeliveryRecord] {
        snapshot.resumeDeliveryRecords.filter { record in
            record.accountID == accountID &&
                record.remoteIdentityID == remoteIdentityID &&
                record.conversationID == conversationID &&
                record.state.blocksAdditionalDelivery(failureCode: record.failureCode)
        }
    }

    private func conversationHasAuthoritativeOutgoingResume(
        accountID: UUID,
        conversationID: String
    ) -> Bool {
        snapshot.conversations.first(where: {
            $0.accountID == accountID &&
                ($0.id == conversationID || $0.remoteConversationID == conversationID)
        })?.messages.contains(where: { message in
            message.isAuthoritativeHistoryRecord == true &&
                message.hasAuthoritativeDirection == true &&
                message.direction == .outgoing &&
                message.remoteBodyType == 12 &&
                message.hyperLinkType == 1 &&
                message.hyperLinkResumeToken?.appStoreNonempty != nil
        }) == true
    }

    private func bossHistoryMessageIdentifier(
        accountID: UUID,
        remoteConversationID: String,
        remoteMID: String
    ) -> String {
        let material = [accountID.uuidString, remoteConversationID, remoteMID]
            .joined(separator: "|")
        return "boss-mid-\(StableIdentifier.fnv1a64(material))"
    }

    private func bossAuthoritativeDirection(
        message: BossResumeHistoryMessage,
        currentUserID: String
    ) -> (direction: MessageDirection, isAuthoritative: Bool) {
        // isSelf 仅为页面推断；只有无歧义的收发双方身份才能授权外部操作。
        guard let senderID = message.senderID?.appStoreNonempty,
              let recipientID = message.recipientID?.appStoreNonempty,
              senderID != recipientID else {
            return (.system, false)
        }
        if senderID == currentUserID, recipientID != currentUserID {
            return (.outgoing, true)
        }
        if recipientID == currentUserID, senderID != currentUserID {
            return (.incoming, true)
        }
        return (.system, false)
    }

    private func bossHistoryDate(milliseconds: Int64?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let seconds = milliseconds > 10_000_000_000
            ? TimeInterval(milliseconds) / 1_000
            : TimeInterval(milliseconds)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func bossMessageSort(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
        return bossMessageIDPrecedes(lhs.remoteMID ?? lhs.id, rhs.remoteMID ?? rhs.id)
    }

    private func bossMessageIDPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = ResumeDeliveryDigestPolicy.normalizedRemoteMID(lhs)
        let right = ResumeDeliveryDigestPolicy.normalizedRemoteMID(rhs)
        if let left, let right {
            if left.count != right.count { return left.count < right.count }
            if left != right { return left < right }
        } else if (left != nil) != (right != nil) {
            return left != nil
        }
        return lhs < rhs
    }

    private func bossResumeConsentEvidence(
        message: ChatMessage,
        conversation: Conversation,
        remoteIdentityID: String
    ) -> ResumeConsentEvidence? {
        guard message.isAuthoritativeHistoryRecord == true,
              message.hasAuthoritativeConsentPayload == true,
              message.hasAuthoritativeDirection == true,
              message.direction == .incoming,
              let remoteMID = message.remoteMID?.appStoreNonempty,
              remoteMID.count <= 4_096 else {
            return nil
        }

        let exchangeKind: BossResumeExchangeKind
        let digestMaterial: String
        let nativeActionAID: Int?
        if message.dialogType == 2,
           message.dialogWasOperated == false,
           message.dialogButtonActionAID == 38 {
            // 原生索要简历为 type-2 对话卡片，按钮 URL 含 aid=38；body.action.aid 不作为授权依据。
            exchangeKind = .acceptNativeRequest
            nativeActionAID = 38
            digestMaterial = [
                "native-resume-dialog-request",
                remoteMID,
                String(message.dialogType ?? -1),
                String(message.dialogWasOperated ?? true),
                String(message.dialogButtonActionAID ?? -1),
                String(message.dialogButtonScene ?? -1)
            ].joined(separator: "|")
        } else {
            // 未知动作卡片即使提到简历，也不能降级为普通文本同意。
            guard message.remoteActionAID == nil,
                  message.dialogButtonActionAID == nil,
                  message.dialogType == nil,
                  let text = message.text.appStoreNonempty else { return nil }
            let decision = ConversationPolicy.classify(text)
            guard decision.intent == .resumeAccepted,
                  decision.shouldCreateResumeTask,
                  decision.confidence >= 0.90 else { return nil }
            exchangeKind = .requestRecruiterConfirmation
            nativeActionAID = nil
            digestMaterial = "explicit-resume-consent|\(text)"
        }

        return ResumeConsentEvidence(
            accountID: conversation.accountID,
            remoteIdentityID: remoteIdentityID,
            conversationID: conversation.id,
            triggerRemoteMID: remoteMID,
            triggerTextDigest: bossSHA256Hex(digestMaterial),
            receivedAt: message.sentAt,
            exchangeKind: exchangeKind,
            nativeActionAID: nativeActionAID,
            nativeScene: message.dialogButtonScene,
            nativeDialogType: exchangeKind == .acceptNativeRequest ? message.dialogType : nil,
            nativeDialogWasOperated: exchangeKind == .acceptNativeRequest
                ? message.dialogWasOperated
                : nil
        )
    }

    private func bossSHA256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func insertManualResumeActionIfNeeded(evidence: ResumeConsentEvidence) {
        guard let conversation = snapshot.conversations.first(where: {
            $0.id == evidence.conversationID && $0.accountID == evidence.accountID
        }) else { return }
        let duplicate = snapshot.pendingActions.contains {
            $0.accountID == evidence.accountID &&
                $0.conversationID == evidence.conversationID &&
                $0.kind == .sendResume &&
                $0.status.requiresAttention
        }
        guard !duplicate else { return }
        snapshot.pendingActions.insert(
            PendingAction(
                accountID: evidence.accountID,
                conversationID: evidence.conversationID,
                kind: .sendResume,
                content: "对方已明确同意继续沟通或接收简历，请在 BOSS 官方会话中核对并发送附件简历。",
                reason: "来自 BOSS 完整历史消息的权威沟通意愿证据，当前未开启自动发送简历。"
            ),
            at: 0
        )
        appendActivity(
            accountID: evidence.accountID,
            level: .warning,
            title: "招聘方已同意继续沟通",
            detail: "\(conversation.company) · \(conversation.jobTitle)：已加入手工发送待办。"
        )
    }

    private func insertQuestionActionIfNeeded(message: ChatMessage, conversation: Conversation) {
        guard message.isAuthoritativeHistoryRecord == true,
              message.hasAuthoritativeDirection == true,
              message.direction == .incoming,
              ConversationPolicy.classify(message.text).intent == .question,
              let action = ConversationPolicy.attentionTask(
                for: conversation,
                latestMessage: message,
                existingActions: snapshot.pendingActions
              ) else { return }
        snapshot.pendingActions.insert(action, at: 0)
        appendActivity(
            accountID: conversation.accountID,
            level: .info,
            title: "招聘方有问题需要处理",
            detail: "\(conversation.company) · \(conversation.jobTitle)：已加入回复待办。"
        )
    }

    func markConversationRead(id: String) {
        guard let index = snapshot.conversations.firstIndex(where: { $0.id == id }) else { return }
        snapshot.conversations[index].unreadCount = 0
        scheduleSave()
    }

    func markConversationHandled(id: String) { markConversationsHandled(ids: [id]) }

    func markConversationsHandled(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let actions = Dictionary(grouping: snapshot.pendingActions, by: \.conversationID)
        let deliveries = Dictionary(grouping: snapshot.resumeDeliveryRecords, by: \.conversationID)
        var updated = snapshot
        let now = Date()
        for index in updated.conversations.indices where ids.contains(updated.conversations[index].id) {
            let conversation = updated.conversations[index]
            let attention = ConversationPolicy.attentionUpdatedAt(for: conversation,
                actions: (actions[conversation.id] ?? []).filter { $0.accountID == conversation.accountID },
                deliveryRecords: (deliveries[conversation.id] ?? []).filter { $0.accountID == conversation.accountID })
            updated.conversations[index].handledAt = max(now, attention ?? .distantPast)
            updated.conversations[index].unreadCount = 0
        }
        for index in updated.pendingActions.indices where updated.pendingActions[index].conversationID.map(ids.contains) == true
            && updated.pendingActions[index].status.requiresAttention {
            updated.pendingActions[index].status = .completed
        }
        snapshot = updated
        scheduleSave()
    }

    func removeConversation(id: String) { removeConversations(ids: [id]) }

    func removeConversations(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var updated = snapshot
        updated.conversations.removeAll { ids.contains($0.id) }
        updated.pendingActions.removeAll { $0.conversationID.map(ids.contains) == true }
        snapshot = updated
        if selectedConversationID.map(ids.contains) == true { selectedConversationID = nil }
        scheduleSave()
    }

    func createDraftAction(
        accountID: UUID,
        conversationID: String?,
        jobID: String?,
        kind: PendingActionKind,
        content: String,
        reason: String
    ) {
        guard snapshot.automation.allowsDrafting,
              snapshot.accounts.contains(where: { $0.id == accountID }) else { return }
        if let conversationID,
           !snapshot.conversations.contains(where: { $0.id == conversationID && $0.accountID == accountID }) {
            return
        }
        if let jobID,
           !snapshot.jobs.contains(where: { $0.id == jobID && $0.accountID == accountID }) {
            return
        }
        let duplicate = snapshot.pendingActions.contains {
            $0.accountID == accountID &&
            $0.conversationID == conversationID &&
            $0.jobID == jobID &&
            $0.kind == kind &&
            $0.status.requiresAttention
        }
        guard !duplicate else { return }
        snapshot.pendingActions.insert(
            PendingAction(
                accountID: accountID,
                conversationID: conversationID,
                jobID: jobID,
                kind: kind,
                content: content,
                reason: reason
            ),
            at: 0
        )
        scheduleSave()
    }

    func setActionStatus(id: UUID, status: PendingActionStatus) {
        guard let index = snapshot.pendingActions.firstIndex(where: { $0.id == id }) else { return }
        snapshot.pendingActions[index].status = status
        let accountID = snapshot.pendingActions[index].accountID
        if !status.requiresAttention,
           let conversationID = snapshot.pendingActions[index].conversationID,
           !snapshot.pendingActions.contains(where: {
               $0.accountID == accountID &&
                   $0.conversationID == conversationID &&
                   $0.status.requiresAttention
           }),
           snapshot.conversations.contains(where: {
               $0.accountID == accountID && $0.id == conversationID
           }) {
            markConversationHandled(id: conversationID)
            return
        }
        scheduleSave()
    }

    func addActivity(
        accountID: UUID? = nil,
        level: ActivityLevel,
        title: String,
        detail: String
    ) {
        appendActivity(accountID: accountID, level: level, title: title, detail: detail)
        scheduleSave()
    }

    private func appendActivity(
        accountID: UUID? = nil,
        level: ActivityLevel,
        title: String,
        detail: String
    ) {
        if let accountID,
           !snapshot.accounts.contains(where: { $0.id == accountID }) {
            return
        }
        snapshot.activity.insert(
            ActivityEntry(accountID: accountID, level: level, title: title, detail: detail),
            at: 0
        )
        if snapshot.activity.count > 500 {
            snapshot.activity.removeLast(snapshot.activity.count - 500)
        }
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
        addActivity(level: .error, title: "操作失败", detail: error.localizedDescription)
    }

    func flush() {
        guard !persistenceBlocked else { return }
        saveTask?.cancel()
        do {
            try persistence.save(snapshot)
        } catch {
            lastError = "保存本地数据失败：\(error.localizedDescription)"
        }
    }

    /// 排在已有保存之后写入最新快照，退出等待磁盘时保持主线程响应。
    func flushForTermination() async {
        guard !persistenceBlocked else { return }
        saveTask?.cancel()
        saveTask = nil
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                persistence.saveInBackground(snapshot) { continuation.resume(with: $0) }
            }
        } catch {
            lastError = "保存本地数据失败：\(error.localizedDescription)"
        }
    }

    /// 简历写入同步持久化；失败时恢复完整内存快照，禁止以未落盘许可继续外发。
    private func persistResumeDeliveryMutation<Result>(
        _ mutation: () throws -> Result
    ) throws -> Result {
        guard !persistenceBlocked else {
            throw ResumeDeliveryStoreError.persistenceUnavailable
        }
        let previousSnapshot = snapshot
        saveTask?.cancel()
        saveTask = nil
        do {
            let result = try mutation()
            try persistence.save(snapshot)
            return result
        } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    func scheduleSave() {
        guard !persistenceBlocked else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.persistence.saveInBackground(self.snapshot) { continuation.resume(with: $0) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.lastError = "保存本地数据失败：\(error.localizedDescription)"
            }
        }
    }

    private func invalidateMatchingResults(in state: inout AppSnapshot) {
        for index in state.jobs.indices {
            state.jobs[index].assessment = nil
            state.jobs[index].stage = invalidatedStage(from: state.jobs[index].stage)
        }
        state.pendingActions.removeAll {
            $0.kind == .sendGreeting && $0.status.requiresAttention
        }
    }

    private func invalidatedStage(from stage: JobStage) -> JobStage {
        switch stage {
        case .discovered, .rejected, .recommended:
            return .discovered
        case .greetingDrafted, .contacted, .resumeRequested, .resumeSent, .closed:
            return stage
        }
    }

    private func assessedStage(from stage: JobStage, passesQualityGate: Bool) -> JobStage {
        switch stage {
        case .discovered, .rejected, .recommended:
            return passesQualityGate ? .recommended : .rejected
        case .greetingDrafted, .contacted, .resumeRequested, .resumeSent, .closed:
            return stage
        }
    }
}

private extension String {
    var appStoreNonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
