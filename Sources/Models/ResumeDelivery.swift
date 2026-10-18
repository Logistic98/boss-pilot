import Foundation
import CryptoKit

enum BossResumeExchangeKind: String, Codable, Hashable, Sendable {
    /// 招聘方明确同意沟通后创建附件请求，仍须由其在 BOSS 内确认。
    case requestRecruiterConfirmation
    /// BOSS 原生索要简历卡片，可使用该卡片的 MID 接受并发送附件。
    case acceptNativeRequest
}

enum ResumeDeliveryState: String, Codable, Hashable, Sendable {
    case queued
    case preparingAttachment
    case dispatching
    case requestCreatedAwaitingRecruiter
    case serverAcceptedUnverified
    case confirmed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .confirmed, .failed, .cancelled: true
        default: false
        }
    }

    /// 写入可能已到达 BOSS 后只能核对结果，不得退回排队或提交状态重发。
    var hasUncertainExternalOutcome: Bool {
        switch self {
        case .dispatching, .requestCreatedAwaitingRecruiter, .serverAcceptedUnverified: true
        default: false
        }
    }

    /// 已有进行中、已确认或结果未知的投递时禁止二次发送；明确未提交的失败只能凭新同意重试。
    func blocksAdditionalDelivery(failureCode: ResumeDeliveryFailureCode?) -> Bool {
        switch self {
        case .queued, .preparingAttachment, .dispatching,
             .requestCreatedAwaitingRecruiter, .serverAcceptedUnverified, .confirmed:
            true
        case .failed:
            failureCode == .requestOutcomeUnknown || failureCode == .verificationFailed
        case .cancelled:
            false
        }
    }

    func canTransition(to next: ResumeDeliveryState) -> Bool {
        switch (self, next) {
        case (.queued, .preparingAttachment),
             (.queued, .dispatching),
             (.queued, .failed),
             (.queued, .cancelled),
             (.preparingAttachment, .queued),
             (.preparingAttachment, .dispatching),
             (.preparingAttachment, .failed),
             (.preparingAttachment, .cancelled),
             (.dispatching, .requestCreatedAwaitingRecruiter),
             (.dispatching, .serverAcceptedUnverified),
             (.dispatching, .confirmed),
             (.dispatching, .failed),
             (.requestCreatedAwaitingRecruiter, .confirmed),
             (.requestCreatedAwaitingRecruiter, .failed),
             (.serverAcceptedUnverified, .confirmed),
             (.serverAcceptedUnverified, .failed):
            true
        default:
            false
        }
    }

    var requiresRemoteResumeBinding: Bool {
        switch self {
        case .dispatching, .requestCreatedAwaitingRecruiter, .serverAcceptedUnverified, .confirmed:
            true
        default:
            false
        }
    }

    /// BOSS 接受附件发送即计为已交换，历史回读仅提升可信度，不重复计数。
    var countsAsResumeExchange: Bool {
        switch self {
        case .serverAcceptedUnverified, .confirmed: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .queued: "待发送"
        case .preparingAttachment: "正在准备附件"
        case .dispatching: "正在提交"
        case .requestCreatedAwaitingRecruiter: "已发起附件简历请求"
        case .serverAcceptedUnverified: "BOSS 已接受发送操作"
        case .confirmed: "已回读确认"
        case .failed: "发送失败"
        case .cancelled: "已取消"
        }
    }
}

/// 投递失败仅保存固定分类，不写入响应原文、请求、凭据、路径或本地化错误。
enum ResumeDeliveryFailureCode: String, Codable, Hashable, Sendable {
    case attachmentPreparationFailed
    case attachmentUploadFailed
    case authenticationRequired
    case requestRejected
    case requestOutcomeUnknown
    case invalidResponse
    case verificationFailed
    case cancelled
    case unknown
}

enum ResumeDeliveryStoreError: LocalizedError, Equatable {
    case persistenceUnavailable
    case evidenceNotAuthoritative
    case evidenceNotCurrentHistory
    case accountIdentityMismatch
    case conversationMismatch
    case invalidAttachmentDigest
    case duplicateConsent
    case deliveryAlreadyExists
    case recordMissing
    case invalidNativePromotion
    case invalidRemoteResumeBinding
    case remoteResumeBindingMissing
    case invalidTransition(from: ResumeDeliveryState, to: ResumeDeliveryState)
    case failureCodeRequired
    case unexpectedFailureCode

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            "本地投递状态当前不可写，已禁止发送。"
        case .evidenceNotAuthoritative:
            "招聘方同意证据不完整，已禁止发送。"
        case .evidenceNotCurrentHistory:
            "附件简历投递证据与当前 BOSS 完整历史消息不一致，已禁止发送。"
        case .accountIdentityMismatch:
            "投递证据与当前 BOSS 账号身份不一致，已禁止发送。"
        case .conversationMismatch:
            "投递证据无法绑定到当前招聘会话，已禁止发送。"
        case .invalidAttachmentDigest:
            "附件简历摘要无效，已禁止发送。"
        case .duplicateConsent:
            "该招聘方同意记录已经处理过，禁止重复发送。"
        case .deliveryAlreadyExists:
            "该招聘会话已发送过简历或存在可能已发送的记录，禁止二次发送。"
        case .recordMissing:
            "附件简历投递记录不存在。"
        case .invalidNativePromotion:
            "BOSS 原生简历请求与已发起的附件简历会话无法唯一关联。"
        case .invalidRemoteResumeBinding:
            "BOSS 附件简历绑定无效。"
        case .remoteResumeBindingMissing:
            "尚未保存可用的 BOSS 附件简历绑定。"
        case .invalidTransition:
            "附件简历投递状态转换无效，已禁止继续发送。"
        case .failureCodeRequired:
            "失败状态缺少安全的错误分类。"
        case .unexpectedFailureCode:
            "非失败状态不能保存错误分类。"
        }
    }
}

enum ResumeDeliveryDigestPolicy {
    static func normalizedAttachmentSHA256(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.unicodeScalars.allSatisfy(isLowercaseHex) else {
            return nil
        }
        return normalized
    }

    static func normalizedEvidenceDigest(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (16...128).contains(normalized.count), normalized.unicodeScalars.allSatisfy(isLowercaseHex) else {
            return nil
        }
        return normalized
    }

    static func normalizedRemoteMID(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= 32,
              raw.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        let trimmed = raw.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    static func remoteMID(_ candidate: String, isStrictlyNewerThan baseline: String) -> Bool {
        guard let candidate = normalizedRemoteMID(candidate),
              let baseline = normalizedRemoteMID(baseline) else { return false }
        if candidate.count != baseline.count { return candidate.count > baseline.count }
        return candidate > baseline
    }

    private static func isLowercaseHex(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 97...102: true
        default: false
        }
    }
}

struct ResumeConsentEvidence: Codable, Hashable, Sendable {
    var accountID: UUID
    var remoteIdentityID: String
    var conversationID: String
    var triggerRemoteMID: String
    var triggerTextDigest: String
    var receivedAt: Date
    var exchangeKind: BossResumeExchangeKind
    var nativeActionAID: Int?
    var nativeScene: Int?
    var nativeDialogType: Int? = nil
    var nativeDialogWasOperated: Bool? = nil

    var isAuthoritativeNativeRequest: Bool {
        isAuthoritative &&
            exchangeKind == .acceptNativeRequest &&
            nativeDialogType == 2 &&
            nativeDialogWasOperated == false &&
            nativeActionAID == 38 &&
            !triggerRemoteMID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isAuthoritative: Bool {
        let remoteIdentityID = remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerRemoteMID = triggerRemoteMID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteIdentityID.isEmpty,
              !conversationID.isEmpty,
              !triggerRemoteMID.isEmpty,
              remoteIdentityID.count <= 4_096,
              conversationID.count <= 4_096,
              triggerRemoteMID.count <= 4_096,
              ResumeDeliveryDigestPolicy.normalizedEvidenceDigest(triggerTextDigest) != nil else {
            return false
        }
        switch exchangeKind {
        case .requestRecruiterConfirmation:
            return true
        case .acceptNativeRequest:
            return nativeDialogType == 2 &&
                nativeDialogWasOperated == false &&
                nativeActionAID == 38
        }
    }
}

/// 按身份保存不含原值的防重哈希，账号重建及 A→B→A 切换后仍有效。
struct ResumeConsentSafetyRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var identityFingerprint: String
    var preparedAt: Date

    init(evidence: ResumeConsentEvidence, preparedAt: Date) {
        self.init(
            remoteIdentityID: evidence.remoteIdentityID,
            triggerRemoteMID: evidence.triggerRemoteMID,
            preparedAt: preparedAt
        )
    }

    init(record: ResumeDeliveryRecord) {
        self.init(
            remoteIdentityID: record.remoteIdentityID,
            triggerRemoteMID: record.triggerRemoteMID,
            preparedAt: record.createdAt
        )
    }

    init(remoteIdentityID: String, triggerRemoteMID: String, preparedAt: Date) {
        let identity = remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageID = triggerRemoteMID.trimmingCharacters(in: .whitespacesAndNewlines)
        id = Self.identifier(remoteIdentityID: identity, triggerRemoteMID: messageID)
        identityFingerprint = Self.identityFingerprint(remoteIdentityID: identity)
        self.preparedAt = preparedAt
    }

    static func identifier(remoteIdentityID: String, triggerRemoteMID: String) -> String {
        let identity = remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageID = triggerRemoteMID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "resume-consent-safety-\(sha256(lengthPrefixed([identity, messageID])))"
    }

    static func identityFingerprint(remoteIdentityID: String) -> String {
        let identity = remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "boss-identity-sha256-\(sha256(lengthPrefixed([identity])))"
    }

    private static func lengthPrefixed(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct PreparedResumeAttachment: Codable, Hashable, Sendable {
    var fileURL: URL
    var sha256: String
    var mimeType: String
    var byteCount: Int
    var sourceModifiedAt: Date
}

struct BossRemoteResumeBinding: Codable, Hashable, Sendable {
    var accountID: UUID
    var remoteIdentityID: String
    var attachmentSHA256: String
    var remoteResumeToken: String
    var remoteDisplayName: String?
    var uploadedAt: Date

    var id: String {
        Self.identifier(remoteIdentityID: remoteIdentityID, attachmentSHA256: attachmentSHA256)
    }

    static func identifier(remoteIdentityID: String, attachmentSHA256: String) -> String {
        "boss-resume-\(StableIdentifier.fnv1a64([remoteIdentityID, attachmentSHA256].joined(separator: "|")))"
    }

    /// 旧字段名为附件 SHA；BOSS 附件使用选择器摘要，不保存远端令牌或本地文件哈希。
    static func selectorDigest(remoteIdentityID: String, remoteResumeToken: String) -> String {
        let identity = remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = remoteResumeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let material = "\(identity.utf8.count):\(identity)\(token.utf8.count):\(token)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ResumeDeliveryRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var accountID: UUID
    var remoteIdentityID: String
    var conversationID: String
    var triggerRemoteMID: String
    var triggerTextDigest: String
    var attachmentSHA256: String
    var exchangeKind: BossResumeExchangeKind
    var nativeActionAID: Int?
    var nativeScene: Int?
    var nativeDialogType: Int? = nil
    var nativeDialogWasOperated: Bool? = nil
    var remoteResumeToken: String?
    /// 在交换请求提交前持久化，作为本次出站附件消息的时间下界。
    var writeStartedAt: Date? = nil
    /// 提交前已知的最大服务端 MID；确认消息的 MID 必须严格大于该值。
    var writeBaselineRemoteMID: String? = nil
    var state: ResumeDeliveryState
    var createdAt: Date
    var updatedAt: Date
    var serverAcceptedAt: Date?
    var verifiedAt: Date?
    var failureCode: ResumeDeliveryFailureCode?

    init(
        evidence: ResumeConsentEvidence,
        attachmentSHA256: String,
        now: Date = Date()
    ) {
        let remoteIdentityID = evidence.remoteIdentityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = evidence.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerRemoteMID = evidence.triggerRemoteMID.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerTextDigest = evidence.triggerTextDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let attachmentSHA256 = attachmentSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        id = Self.identifier(
            remoteIdentityID: remoteIdentityID,
            conversationID: conversationID,
            triggerRemoteMID: triggerRemoteMID,
            attachmentSHA256: attachmentSHA256
        )
        accountID = evidence.accountID
        self.remoteIdentityID = remoteIdentityID
        self.conversationID = conversationID
        self.triggerRemoteMID = triggerRemoteMID
        self.triggerTextDigest = triggerTextDigest
        self.attachmentSHA256 = attachmentSHA256
        exchangeKind = evidence.exchangeKind
        nativeActionAID = evidence.nativeActionAID
        nativeScene = evidence.nativeScene
        nativeDialogType = evidence.nativeDialogType
        nativeDialogWasOperated = evidence.nativeDialogWasOperated
        remoteResumeToken = nil
        writeStartedAt = nil
        writeBaselineRemoteMID = nil
        state = .queued
        createdAt = now
        updatedAt = now
        serverAcceptedAt = nil
        verifiedAt = nil
        failureCode = nil
    }

    static func identifier(
        remoteIdentityID: String,
        conversationID: String,
        triggerRemoteMID: String,
        attachmentSHA256: String
    ) -> String {
        let material = [remoteIdentityID, conversationID, triggerRemoteMID, attachmentSHA256]
            .joined(separator: "|")
        return "resume-delivery-\(StableIdentifier.fnv1a64(material))"
    }

    static func consentIdentifier(
        remoteIdentityID: String,
        conversationID: String,
        triggerRemoteMID: String
    ) -> String {
        let material = [remoteIdentityID, conversationID, triggerRemoteMID]
            .joined(separator: "|")
        return "resume-consent-\(StableIdentifier.fnv1a64(material))"
    }

    var consentIdentifier: String {
        Self.consentIdentifier(
            remoteIdentityID: remoteIdentityID,
            conversationID: conversationID,
            triggerRemoteMID: triggerRemoteMID
        )
    }

    var resumeExchangeAt: Date? {
        guard state.countsAsResumeExchange else { return nil }
        return serverAcceptedAt ?? verifiedAt
    }
}
