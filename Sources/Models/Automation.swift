import Foundation

struct BossJobSearchTarget: Hashable, Sendable {
    let query: String
    let city: String
    let cityCode: String

    init(query: String, city: String, cityCode: String) {
        self.query = BossJobSearchPaginationPolicy.normalizedQuery(query)
        self.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cityCode = cityCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var fingerprintMaterial: String {
        "\(query.utf8.count):\(query)|\(cityCode.utf8.count):\(cityCode)"
    }
}

struct BossJobSearchPaginationState: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var planFingerprint: String
    var nextPage: Int
    var updatedAt: Date

    var id: String {
        let material = [accountID.uuidString, planFingerprint].joined(separator: "|")
        return "boss-search-page-\(StableIdentifier.fnv1a64(material))"
    }
}

enum BossJobSearchPaginationPolicy {
    static let supportedPages = 1...10

    static func normalizedQuery(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(40))
    }

    static func normalizedPage(_ page: Int) -> Int {
        min(supportedPages.upperBound, max(supportedPages.lowerBound, page))
    }

    static func page(after completedPage: Int) -> Int {
        normalizedPage(completedPage) == supportedPages.upperBound
            ? supportedPages.lowerBound
            : normalizedPage(completedPage) + 1
    }

    static func planFingerprint(
        remoteIdentityID: String,
        resumeID: UUID,
        requirementText: String,
        targets: [BossJobSearchTarget]
    ) -> String {
        let identity = remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requirement = requirementText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let targetMaterial = Set(targets.map(\.fingerprintMaterial))
            .sorted()
            .joined(separator: "\u{1e}")
        let material = [
            "identity:\(identity)",
            "resume:\(resumeID.uuidString.lowercased())",
            "requirement:\(requirement)",
            "targets:\(targetMaterial)"
        ].joined(separator: "\u{1f}")
        return "boss-search-plan-\(StableIdentifier.fnv1a64(material))"
    }
}

enum AutomationMode: String, Codable {
    // 旧枚举值仅用于兼容已保存的设置。
    case remindersOnly
    case draftsAndReminders
    case automatic
}

struct AutomationSettings: Codable, Hashable {
    static let monitorIntervalMinutesRange = 30...180
    static let searchIntervalMinutesRange = 30...360
    static let dailyGreetingLimitRange = 1...150
    static let greetingIntervalSecondsRange = 180...1_800
    static let defaultDailyGreetingLimit = 150
    static let defaultMonitorIntervalMinutes = 60
    static let defaultSearchIntervalMinutes = 60
    static let defaultGreetingIntervalSeconds = 180
    static let legacyDailyGreetingLimitBeforeSchema5 = 10

    var mode: AutomationMode = .automatic
    var automaticallyAssessJobs: Bool = true
    var automaticallyDraftReplies: Bool = true
    var allowRecruiterTextToCodex: Bool = false
    var workerEnabled: Bool = false
    var automaticallySearchJobs: Bool = true
    var automaticallyMonitorMessages: Bool = true
    var automaticallySendGreetings: Bool = true
    var automaticallySendResume: Bool = false
    var monitorIntervalMinutes: Int = Self.defaultMonitorIntervalMinutes
    var searchIntervalMinutes: Int = Self.defaultSearchIntervalMinutes
    var dailyGreetingLimit: Int = Self.defaultDailyGreetingLimit
    var greetingIntervalSeconds: Int = Self.defaultGreetingIntervalSeconds
    var safetyCooldownUntil: Date?
    var jobSearchPaginationStates: [BossJobSearchPaginationState] = []

    var allowsDrafting: Bool { mode != .remindersOnly }
    var allowsConnectorReads: Bool { mode != .remindersOnly }
    var allowsExternalActions: Bool { mode == .automatic }

    enum CodingKeys: String, CodingKey {
        case mode
        case automaticallyAssessJobs, automaticallyDraftReplies, allowRecruiterTextToCodex
        case workerEnabled, automaticallySearchJobs, automaticallyMonitorMessages
        case automaticallySendGreetings, automaticallySendResume
        case monitorIntervalMinutes, searchIntervalMinutes, dailyGreetingLimit, greetingIntervalSeconds
        case safetyCooldownUntil
        case jobSearchPaginationStates
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AutomationMode.self, forKey: .mode) ?? .draftsAndReminders
        automaticallyAssessJobs = try container.decodeIfPresent(Bool.self, forKey: .automaticallyAssessJobs) ?? true
        automaticallyDraftReplies = try container.decodeIfPresent(Bool.self, forKey: .automaticallyDraftReplies) ?? true
        allowRecruiterTextToCodex = try container.decodeIfPresent(Bool.self, forKey: .allowRecruiterTextToCodex) ?? false
        workerEnabled = try container.decodeIfPresent(Bool.self, forKey: .workerEnabled) ?? false
        automaticallySearchJobs = try container.decodeIfPresent(Bool.self, forKey: .automaticallySearchJobs) ?? true
        automaticallyMonitorMessages = try container.decodeIfPresent(Bool.self, forKey: .automaticallyMonitorMessages) ?? true
        automaticallySendGreetings = try container.decodeIfPresent(Bool.self, forKey: .automaticallySendGreetings) ?? false
        automaticallySendResume = try container.decodeIfPresent(Bool.self, forKey: .automaticallySendResume) ?? false
        monitorIntervalMinutes = Self.normalizedMonitorIntervalMinutes(
            try container.decodeIfPresent(Int.self, forKey: .monitorIntervalMinutes) ??
                Self.defaultMonitorIntervalMinutes
        )
        searchIntervalMinutes = Self.normalizedSearchIntervalMinutes(
            try container.decodeIfPresent(Int.self, forKey: .searchIntervalMinutes) ??
                Self.defaultSearchIntervalMinutes
        )
        dailyGreetingLimit = Self.normalizedDailyGreetingLimit(
            try container.decodeIfPresent(Int.self, forKey: .dailyGreetingLimit) ?? Self.defaultDailyGreetingLimit
        )
        greetingIntervalSeconds = Self.normalizedGreetingIntervalSeconds(
            try container.decodeIfPresent(Int.self, forKey: .greetingIntervalSeconds) ?? Self.defaultGreetingIntervalSeconds
        )
        safetyCooldownUntil = try container.decodeIfPresent(Date.self, forKey: .safetyCooldownUntil)
        let decodedPaginationStates = try container.decodeIfPresent(
            [BossJobSearchPaginationState].self,
            forKey: .jobSearchPaginationStates
        ) ?? []
        var latestPaginationStateByAccount: [UUID: BossJobSearchPaginationState] = [:]
        for var state in decodedPaginationStates where !state.planFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.nextPage = BossJobSearchPaginationPolicy.normalizedPage(state.nextPage)
            if let existing = latestPaginationStateByAccount[state.accountID],
               existing.updatedAt > state.updatedAt {
                continue
            }
            latestPaginationStateByAccount[state.accountID] = state
        }
        jobSearchPaginationStates = latestPaginationStateByAccount.values.sorted {
            $0.accountID.uuidString < $1.accountID.uuidString
        }
        enforceAutomaticModeCapabilities()
    }

    static func normalizedDailyGreetingLimit(_ value: Int) -> Int {
        min(dailyGreetingLimitRange.upperBound, max(dailyGreetingLimitRange.lowerBound, value))
    }

    static func normalizedMonitorIntervalMinutes(_ value: Int) -> Int {
        min(monitorIntervalMinutesRange.upperBound, max(monitorIntervalMinutesRange.lowerBound, value))
    }

    static func normalizedSearchIntervalMinutes(_ value: Int) -> Int {
        min(searchIntervalMinutesRange.upperBound, max(searchIntervalMinutesRange.lowerBound, value))
    }

    static func normalizedGreetingIntervalSeconds(_ value: Int) -> Int {
        min(greetingIntervalSecondsRange.upperBound, max(greetingIntervalSecondsRange.lowerBound, value))
    }

    mutating func enforceAutomaticModeCapabilities() {
        if mode != .automatic { workerEnabled = false }
        mode = .automatic
        automaticallySearchJobs = true
        automaticallyAssessJobs = true
        automaticallySendGreetings = true
    }

    func nextJobSearchPage(accountID: UUID, planFingerprint: String) -> Int {
        guard let state = jobSearchPaginationStates.first(where: {
            $0.accountID == accountID && $0.planFingerprint == planFingerprint
        }) else {
            return BossJobSearchPaginationPolicy.supportedPages.lowerBound
        }
        return BossJobSearchPaginationPolicy.normalizedPage(state.nextPage)
    }

    func lastCompletedJobSearchAt(accountID: UUID, planFingerprint: String) -> Date? {
        jobSearchPaginationStates.first {
            $0.accountID == accountID && $0.planFingerprint == planFingerprint
        }?.updatedAt
    }

    mutating func recordCompletedJobSearchPage(
        accountID: UUID,
        planFingerprint: String,
        completedPage: Int,
        now: Date = Date()
    ) {
        let normalizedFingerprint = planFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFingerprint.isEmpty else { return }
        jobSearchPaginationStates.removeAll { $0.accountID == accountID }
        jobSearchPaginationStates.append(
            BossJobSearchPaginationState(
                accountID: accountID,
                planFingerprint: normalizedFingerprint,
                nextPage: BossJobSearchPaginationPolicy.page(after: completedPage),
                updatedAt: now
            )
        )
        jobSearchPaginationStates.sort { $0.accountID.uuidString < $1.accountID.uuidString }
    }
}

enum PendingActionKind: String, Codable {
    case sendGreeting
    case sendResume
    case sendMessage

    var title: String {
        switch self {
        case .sendGreeting: "发送招呼"
        case .sendResume: "发送简历"
        case .sendMessage: "发送回复"
        }
    }
}

enum PendingActionStatus: String, Codable {
    case pending
    case copied
    case completed
    case dismissed
    case failed

    var requiresAttention: Bool {
        self == .pending || self == .copied
    }
}

struct PendingAction: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var accountID: UUID
    var conversationID: String? = nil
    var jobID: String? = nil
    var kind: PendingActionKind
    var content: String
    var reason: String
    var status: PendingActionStatus = .pending
    var createdAt: Date = Date()
}

enum ActivityLevel: String, Codable {
    case info
    case success
    case warning
    case error
}

struct ActivityEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var accountID: UUID?
    var level: ActivityLevel
    var title: String
    var detail: String
    var createdAt: Date = Date()
}

struct AutomaticGreetingAttempt: Identifiable, Codable, Hashable {
    var id: String
    var accountID: UUID
    var remoteIdentityID: String
    var remoteJobID: String
    var attemptedAt: Date
    var deliveryWriteStartedAt: Date?
    var succeededAt: Date?
    var confirmedMessageID: String?

    init(
        accountID: UUID,
        remoteIdentityID: String,
        remoteJobID: String,
        attemptedAt: Date = Date(),
        deliveryWriteStartedAt: Date? = nil,
        succeededAt: Date? = nil,
        confirmedMessageID: String? = nil
    ) {
        self.id = Self.identifier(remoteIdentityID: remoteIdentityID, remoteJobID: remoteJobID)
        self.accountID = accountID
        self.remoteIdentityID = remoteIdentityID
        self.remoteJobID = remoteJobID
        self.attemptedAt = attemptedAt
        self.deliveryWriteStartedAt = deliveryWriteStartedAt
        self.succeededAt = succeededAt
        self.confirmedMessageID = confirmedMessageID
    }

    static func identifier(remoteIdentityID: String, remoteJobID: String) -> String {
        "greeting-\(StableIdentifier.fnv1a64([remoteIdentityID, remoteJobID].joined(separator: "|")))"
    }
}

/// 按身份保存防重指纹与时间，退出或重建本地账号后仍有效；不保存身份、岗位或消息原文。
struct AutomaticGreetingSafetyRecord: Identifiable, Codable, Hashable {
    var id: String
    var identityFingerprint: String
    var attemptedAt: Date
    var recipientFingerprint: String? = nil

    init(remoteIdentityID: String, remoteJobID: String, attemptedAt: Date, remoteRecipientID: String? = nil) {
        self.id = AutomaticGreetingAttempt.identifier(
            remoteIdentityID: remoteIdentityID,
            remoteJobID: remoteJobID
        )
        self.identityFingerprint = Self.identityFingerprint(remoteIdentityID: remoteIdentityID)
        self.attemptedAt = attemptedAt
        self.recipientFingerprint = remoteRecipientID.map {
            AutomaticGreetingAttempt.identifier(remoteIdentityID: remoteIdentityID, remoteJobID: "recipient:\($0)")
        }
    }

    init(attempt: AutomaticGreetingAttempt) {
        self.init(
            remoteIdentityID: attempt.remoteIdentityID,
            remoteJobID: attempt.remoteJobID,
            attemptedAt: attempt.attemptedAt
        )
    }

    static func identityFingerprint(remoteIdentityID: String) -> String {
        "boss-identity-\(StableIdentifier.fnv1a64(remoteIdentityID))"
    }
}

enum AutomaticGreetingPacingPolicy {
    static let maximumJitterSeconds = 15

    static func nextAllowedAt(
        after record: AutomaticGreetingSafetyRecord,
        intervalSeconds: Int
    ) -> Date {
        let normalizedSeconds = AutomationSettings.normalizedGreetingIntervalSeconds(intervalSeconds)
        let stableHash = UInt64(StableIdentifier.fnv1a64(record.id), radix: 16) ?? 0
        let jitterSeconds = Int(stableHash % UInt64(maximumJitterSeconds + 1))
        return record.attemptedAt.addingTimeInterval(
            TimeInterval(normalizedSeconds + jitterSeconds)
        )
    }
}

enum JobDetailBatchPolicy {
    static let maximumDetailsPerPass = 4
    static let minimumPersistedBacklogShare = 1
    static let candidateBufferSize = 8

    static func needsCandidates(queuedCount: Int, usedDailyQuota: Int, dailyLimit: Int) -> Bool {
        queuedCount < candidateBufferSize && usedDailyQuota < dailyLimit
    }

    static func canReadDetail(lastFailureAt: Date?, now: Date = Date()) -> Bool {
        lastFailureAt.map { now.timeIntervalSince($0) >= 15 * 60 } ?? true
    }

    static func priorityScores(jobs: [JobListing], preferences: JobPreferences) throws -> [String: Int] {
        var scores: [String: Int] = [:]
        for job in jobs {
            try Task.checkCancellation()
            guard let remoteJobID = job.remoteJobID else { continue }
            scores[remoteJobID] = JobMatchingPolicy.hardGateFailures(job: job, preferences: preferences).count
        }
        return scores
    }

    static func selectedIndices(
        hasCachedDetail: [Bool],
        hasSecurityID: [Bool],
        limit: Int = maximumDetailsPerPass
    ) -> [Int] {
        guard hasCachedDetail.count == hasSecurityID.count else { return [] }
        return hasCachedDetail.indices
            .filter { !hasCachedDetail[$0] && hasSecurityID[$0] }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 为离开当前搜索页的缓存岗位保留详情读取预算，剩余预算由有任务的一侧使用。
    static func startupAllocation(currentCount: Int, persistedCount: Int) -> [Int] {
        currentCount > 0 ? [min(2, currentCount), 0] : [0, min(2, max(0, persistedCount))]
    }

    static func allocation(currentCount: Int, persistedCount: Int) -> [Int] {
        let currentCount = max(0, currentCount)
        let persistedCount = max(0, persistedCount)
        let reservedPersisted = min(
            persistedCount,
            currentCount > 0 ? minimumPersistedBacklogShare : maximumDetailsPerPass
        )
        let current = min(currentCount, maximumDetailsPerPass - reservedPersisted)
        let persisted = min(persistedCount, maximumDetailsPerPass - current)
        return [current, persisted]
    }
}

enum BossRequestPacingPolicy {
    static let minimumReadIntervalSeconds: TimeInterval = 10
    static let maximumReadJitterSeconds = 2
    static let minimumWriteIntervalSeconds: TimeInterval = 60
    static let maximumWriteJitterSeconds = 4

    static func nextAllowedAt(
        lastDispatchedAt: Date?,
        lastWriteAt: Date?,
        isWrite: Bool,
        readJitter: Int,
        writeJitter: Int,
        now: Date
    ) -> Date {
        let requestDue = lastDispatchedAt?.addingTimeInterval(
            minimumReadIntervalSeconds + TimeInterval(readJitter)
        ) ?? now
        guard isWrite else { return requestDue }
        let writeDue = lastWriteAt?.addingTimeInterval(
            minimumWriteIntervalSeconds + TimeInterval(writeJitter)
        ) ?? now
        return max(requestDue, writeDue)
    }

    static func jitterSeconds(discriminator: String, sequence: UInt64, isWrite: Bool) -> Int {
        let ceiling = isWrite ? maximumWriteJitterSeconds : maximumReadJitterSeconds
        let stableHash = UInt64(
            StableIdentifier.fnv1a64("\(discriminator)|\(sequence)"),
            radix: 16
        ) ?? 0
        return Int(stableHash % UInt64(ceiling + 1))
    }
}

enum AutomationWorkerSchedulePolicy {
    static let pollingCeilingSeconds: TimeInterval = 60
    static let retryFloorSeconds: TimeInterval = 10
    static let responsiveWakeFloorSeconds: TimeInterval = 0.25
    static let detailBacklogRetrySeconds: TimeInterval = 15 * 60
    static let candidateReplenishmentIntervalSeconds: TimeInterval = 90

    static func secondsUntilDue(
        lastCompletedAt: Date?,
        intervalMinutes: Int,
        now: Date
    ) -> TimeInterval {
        guard let lastCompletedAt else { return retryFloorSeconds }
        let dueAt = lastCompletedAt.addingTimeInterval(TimeInterval(intervalMinutes * 60))
        return max(retryFloorSeconds, dueAt.timeIntervalSince(now))
    }

    static func jobSearchIsDue(
        lastCompletedAt: Date?,
        intervalMinutes: Int,
        forceInitialSearch: Bool,
        now: Date
    ) -> Bool {
        if forceInitialSearch { return true }
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= TimeInterval(max(1, intervalMinutes) * 60)
    }

    static func detailBacklogIsDue(
        lastAttemptAt: Date?, now: Date,
        intervalSeconds: TimeInterval = detailBacklogRetrySeconds
    ) -> Bool {
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= intervalSeconds
    }

    static func secondsUntilDetailBacklogDue(
        lastAttemptAt: Date?, now: Date,
        intervalSeconds: TimeInterval = detailBacklogRetrySeconds
    ) -> TimeInterval {
        guard let lastAttemptAt else { return retryFloorSeconds }
        return max(
            retryFloorSeconds,
            intervalSeconds - now.timeIntervalSince(lastAttemptAt)
        )
    }

    static func boundedSleepSeconds(
        _ candidates: [TimeInterval],
        minimumSeconds: TimeInterval = retryFloorSeconds
    ) -> TimeInterval {
        min(
            pollingCeilingSeconds,
            max(minimumSeconds, candidates.min() ?? pollingCeilingSeconds)
        )
    }

    static func messageSyncIntervalMinutes(
        hasUnresolvedResumeDelivery: Bool,
        hasReadyResumeDelivery: Bool,
        intervalMinutes: Int
    ) -> Int {
        if hasReadyResumeDelivery { return 3 }
        if hasUnresolvedResumeDelivery { return 5 }
        return max(5, intervalMinutes)
    }

    static func messageSyncIsDue(
        lastCompletedAt: Date?,
        hasUnresolvedResumeDelivery: Bool,
        intervalMinutes: Int,
        now: Date,
        hasReadyResumeDelivery: Bool = false
    ) -> Bool {
        guard let lastCompletedAt else { return true }
        let intervalSeconds = TimeInterval(messageSyncIntervalMinutes(
            hasUnresolvedResumeDelivery: hasUnresolvedResumeDelivery,
            hasReadyResumeDelivery: hasReadyResumeDelivery,
            intervalMinutes: intervalMinutes
        ) * 60)
        return now.timeIntervalSince(lastCompletedAt) >= intervalSeconds
    }
}

struct BossHistoryRouteRotationState: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var remoteIdentityID: String
    var unresolvedOffset: Int
    var regularOffset: Int
    var updatedAt: Date

    var id: String {
        let material = [accountID.uuidString, remoteIdentityID].joined(separator: "|")
        return "boss-history-rotation-\(StableIdentifier.fnv1a64(material))"
    }
}

/// 持久化补缺和回填两组游标；先补齐新消息缺口，再读取旧历史，避免重启后漏读。
struct BossHistoryConversationSyncState: Identifiable, Codable, Hashable, Sendable {
    var accountID: UUID
    var remoteIdentityID: String
    var conversationID: String
    var latestHeadMID: String?
    var gapCursorMID: String?
    var gapTargetMID: String?
    var gapNewHeadMID: String?
    var gapNextPage: Int
    var backfillCursorMID: String?
    var backfillNextPage: Int
    var updatedAt: Date

    init(
        accountID: UUID,
        remoteIdentityID: String,
        conversationID: String,
        latestHeadMID: String?,
        gapCursorMID: String?,
        gapTargetMID: String?,
        gapNewHeadMID: String?,
        gapNextPage: Int = 1,
        backfillCursorMID: String?,
        backfillNextPage: Int = 1,
        updatedAt: Date
    ) {
        self.accountID = accountID
        self.remoteIdentityID = remoteIdentityID
        self.conversationID = conversationID
        self.latestHeadMID = latestHeadMID
        self.gapCursorMID = gapCursorMID
        self.gapTargetMID = gapTargetMID
        self.gapNewHeadMID = gapNewHeadMID
        self.gapNextPage = gapNextPage
        self.backfillCursorMID = backfillCursorMID
        self.backfillNextPage = backfillNextPage
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, remoteIdentityID, conversationID, latestHeadMID
        case gapCursorMID, gapTargetMID, gapNewHeadMID, gapNextPage
        case backfillCursorMID, backfillNextPage, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        remoteIdentityID = try container.decode(String.self, forKey: .remoteIdentityID)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        latestHeadMID = try container.decodeIfPresent(String.self, forKey: .latestHeadMID)
        gapCursorMID = try container.decodeIfPresent(String.self, forKey: .gapCursorMID)
        gapTargetMID = try container.decodeIfPresent(String.self, forKey: .gapTargetMID)
        gapNewHeadMID = try container.decodeIfPresent(String.self, forKey: .gapNewHeadMID)
        gapNextPage = try container.decodeIfPresent(Int.self, forKey: .gapNextPage) ?? 1
        backfillCursorMID = try container.decodeIfPresent(String.self, forKey: .backfillCursorMID)
        backfillNextPage = try container.decodeIfPresent(Int.self, forKey: .backfillNextPage) ?? 1
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    var id: String {
        let material = [accountID.uuidString, remoteIdentityID, conversationID].joined(separator: "|")
        return "boss-history-cursor-\(StableIdentifier.fnv1a64(material))"
    }
}

struct AppSnapshot: Codable {
    var schemaVersion: Int = 25
    var accounts: [BossAccount] = []
    var resume: ResumeProfile = ResumeProfile()
    var preferences: JobPreferences = JobPreferences()
    var codex: CodexConfiguration = CodexConfiguration()
    var automation: AutomationSettings = AutomationSettings()
    var jobs: [JobListing] = []
    var conversations: [Conversation] = []
    var pendingActions: [PendingAction] = []
    var activity: [ActivityEntry] = []
    var automaticGreetingAttempts: [AutomaticGreetingAttempt] = []
    var automaticGreetingSafetyRecords: [AutomaticGreetingSafetyRecord] = []
    var dailyCommunicationRecords: [AutomaticGreetingSafetyRecord] = []
    var dailyCommunicationSyncedAt: [String: Date] = [:]
    var dailyResumeExchangeRecords: [AutomaticGreetingSafetyRecord] = []
    var dailyResumeExchangeSyncedAt: [String: Date] = [:]
    var remoteResumeBindings: [BossRemoteResumeBinding] = []
    var resumeDeliveryRecords: [ResumeDeliveryRecord] = []
    var resumeConsentSafetyRecords: [ResumeConsentSafetyRecord] = []
    var historyRouteRotationStates: [BossHistoryRouteRotationState] = []
    var historyConversationSyncStates: [BossHistoryConversationSyncState] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, resume, preferences, codex, automation
        case jobs, conversations, pendingActions, activity, automaticGreetingAttempts
        case dailyCommunicationRecords, dailyCommunicationSyncedAt
        case dailyResumeExchangeRecords, dailyResumeExchangeSyncedAt
        case automaticGreetingSafetyRecords, remoteResumeBindings, resumeDeliveryRecords
        case resumeConsentSafetyRecords, historyRouteRotationStates, historyConversationSyncStates
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accounts = try container.decodeIfPresent([BossAccount].self, forKey: .accounts) ?? []
        resume = try container.decodeIfPresent(ResumeProfile.self, forKey: .resume) ?? ResumeProfile()
        preferences = try container.decodeIfPresent(JobPreferences.self, forKey: .preferences) ?? JobPreferences()
        codex = try container.decodeIfPresent(CodexConfiguration.self, forKey: .codex) ?? CodexConfiguration()
        automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
        if schemaVersion < 5 {
            let legacyAutomationContainsDailyLimit: Bool
            if container.contains(.automation),
               try !container.decodeNil(forKey: .automation) {
                let legacyAutomation = try container.nestedContainer(
                    keyedBy: AutomationSettings.CodingKeys.self,
                    forKey: .automation
                )
                legacyAutomationContainsDailyLimit = legacyAutomation.contains(.dailyGreetingLimit)
            } else {
                legacyAutomationContainsDailyLimit = false
            }
            if !legacyAutomationContainsDailyLimit {
                automation.dailyGreetingLimit = AutomationSettings.legacyDailyGreetingLimitBeforeSchema5
            }
        }
        jobs = try container.decodeIfPresent([JobListing].self, forKey: .jobs) ?? []
        conversations = try container.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        pendingActions = try container.decodeIfPresent([PendingAction].self, forKey: .pendingActions) ?? []
        activity = try container.decodeIfPresent([ActivityEntry].self, forKey: .activity) ?? []
        automaticGreetingAttempts = try container.decodeIfPresent([AutomaticGreetingAttempt].self, forKey: .automaticGreetingAttempts) ?? []
        automaticGreetingSafetyRecords = try container.decodeIfPresent(
            [AutomaticGreetingSafetyRecord].self,
            forKey: .automaticGreetingSafetyRecords
        ) ?? []
        dailyCommunicationRecords = try container.decodeIfPresent([AutomaticGreetingSafetyRecord].self, forKey: .dailyCommunicationRecords) ?? []
        dailyCommunicationSyncedAt = try container.decodeIfPresent([String: Date].self, forKey: .dailyCommunicationSyncedAt) ?? [:]
        dailyResumeExchangeRecords = try container.decodeIfPresent([AutomaticGreetingSafetyRecord].self, forKey: .dailyResumeExchangeRecords) ?? []
        dailyResumeExchangeSyncedAt = try container.decodeIfPresent([String: Date].self, forKey: .dailyResumeExchangeSyncedAt) ?? [:]
        remoteResumeBindings = try container.decodeIfPresent(
            [BossRemoteResumeBinding].self,
            forKey: .remoteResumeBindings
        ) ?? []
        resumeDeliveryRecords = try container.decodeIfPresent(
            [ResumeDeliveryRecord].self,
            forKey: .resumeDeliveryRecords
        ) ?? []
        resumeConsentSafetyRecords = try container.decodeIfPresent(
            [ResumeConsentSafetyRecord].self,
            forKey: .resumeConsentSafetyRecords
        ) ?? []
        historyRouteRotationStates = try container.decodeIfPresent(
            [BossHistoryRouteRotationState].self,
            forKey: .historyRouteRotationStates
        ) ?? []
        historyConversationSyncStates = try container.decodeIfPresent(
            [BossHistoryConversationSyncState].self,
            forKey: .historyConversationSyncStates
        ) ?? []
    }
}
