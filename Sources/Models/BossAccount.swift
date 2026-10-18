import Foundation

struct BossManualVerificationChallenge: Codable, Hashable, Sendable {
    var code: Int
    var operation: String
    var message: String
    var detectedAt: Date

    var userFacingReason: String {
        "BOSS 要求本人安全验证（\(code)）：\(message)"
    }

    var recoveryInstruction: String {
        "在 BOSS 完成验证后，点击“我已完成，重新检查”。"
    }
}

/// 本人验证响应仅影响当前请求，账号状态以 BOSS 的最新结果为准。
enum BossManualVerificationGate {
    static func allowsAutomaticWork(for account: BossAccount) -> Bool {
        account.status == .active
    }

    static func shouldClear(
        challenge: BossManualVerificationChallenge?,
        explicitRecheckRequested: Bool,
        authoritativeProfileReadSucceeded: Bool
    ) -> Bool {
        false
    }

    static func allowsAuthoritativeProfileRead(
        connectorReadsEnabled: Bool,
        explicitRecheckRequested: Bool
    ) -> Bool {
        connectorReadsEnabled || explicitRecheckRequested
    }
}

/// 独立诊断命令绕过常规调度，访问 BOSS 前仍须检查账号的本人验证限制。
enum BossSmokeCommandSafetyPolicy {
    static func permitsConnectorAccess(for account: BossAccount) -> Bool {
        BossManualVerificationGate.allowsAutomaticWork(for: account)
    }
}

enum AccountStatus: String, Codable, CaseIterable {
    case active
    case paused
    case archived
    case deleting

    var title: String {
        switch self {
        case .active: "使用中"
        case .paused: "已暂停"
        case .archived: "已归档"
        case .deleting: "待完成删除"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "person.crop.circle.badge.checkmark"
        case .paused: "pause.circle"
        case .archived: "archivebox"
        case .deleting: "trash.circle"
        }
    }
}

enum BossLoginStatus: String, Codable {
    case loggedOut
    case loggedIn

    var title: String {
        switch self {
        case .loggedOut: "待扫码"
        case .loggedIn: "已登录"
        }
    }

    var systemImage: String {
        switch self {
        case .loggedOut: "qrcode.viewfinder"
        case .loggedIn: "checkmark.circle.fill"
        }
    }
}

struct BossAccountProfile: Codable, Hashable, Sendable {
    var remoteID: String = ""
    var name: String = ""
    var avatarURL: String = ""
    var currentTitle: String = ""
    var city: String = ""
    var workExperience: String = ""
    var expectations: [String] = []
    var jobStatus: String = ""
    var syncedAt: Date = Date()
    var educationSummary: String? = nil
    var recentWorkSummary: String? = nil
    var selfDescription: String? = nil

    var summary: String {
        [currentTitle, workExperience, city].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct BossAccount: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var customName: String? = nil
    var browserProfileHint: String
    var status: AccountStatus
    var webProfileID: UUID
    var loginStatus: BossLoginStatus
    var createdAt: Date
    var lastLoginAt: Date?
    var lastOfficialCheckAt: Date?
    var lastSyncAt: Date?
    var remoteProfile: BossAccountProfile?
    var manualVerificationChallenge: BossManualVerificationChallenge?
    var notes: String

    init(displayName: String) {
        let id = UUID()
        self.id = id
        self.displayName = displayName
        self.browserProfileHint = ""
        self.status = .active
        self.webProfileID = id
        self.loginStatus = .loggedOut
        self.createdAt = Date()
        self.remoteProfile = nil
        self.manualVerificationChallenge = nil
        self.notes = ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, customName, browserProfileHint, status, webProfileID, loginStatus
        case createdAt, lastLoginAt, lastOfficialCheckAt, lastSyncAt
        case remoteProfile, manualVerificationChallenge, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if customName?.isEmpty == true { customName = nil }
        browserProfileHint = try container.decodeIfPresent(String.self, forKey: .browserProfileHint) ?? ""
        let decodedStatus = try container.decodeIfPresent(AccountStatus.self, forKey: .status) ?? .active
        // 旧版 paused 是本地错误状态，迁移时移除，避免一次请求失败永久停用账号。
        status = decodedStatus == .paused ? .active : decodedStatus
        webProfileID = try container.decodeIfPresent(UUID.self, forKey: .webProfileID) ?? id
        loginStatus = try container.decodeIfPresent(BossLoginStatus.self, forKey: .loginStatus) ?? .loggedOut
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastLoginAt = try container.decodeIfPresent(Date.self, forKey: .lastLoginAt)
        lastOfficialCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastOfficialCheckAt)
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        remoteProfile = try container.decodeIfPresent(BossAccountProfile.self, forKey: .remoteProfile)
        manualVerificationChallenge = try container.decodeIfPresent(
            BossManualVerificationChallenge.self,
            forKey: .manualVerificationChallenge
        )
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

extension BossAccount {
    /// 远端资料刷新保留自定义名称，同名账号仍可区分。
    func selectionLabel(in accounts: [BossAccount]) -> String {
        let current = accounts.first { $0.id == id } ?? self
        let name = current.customName ?? current.displayName
        let sameName = accounts
            .filter { ($0.customName ?? $0.displayName) == name }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt < $1.createdAt
            }
        guard sameName.count > 1,
              let index = sameName.firstIndex(where: { $0.id == id }) else {
            return name
        }
        return "\(name) · 账号 \(index + 1)"
    }
}
