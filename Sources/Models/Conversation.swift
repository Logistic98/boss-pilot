import Foundation

enum MessageDirection: String, Codable {
    case incoming
    case outgoing
    case system
}

enum RecruiterIntent: String, Codable, CaseIterable {
    case resumeAccepted = "resume_accepted"
    case rejected
    case question
    case greeting
    case unknown

    var title: String {
        switch self {
        case .resumeAccepted: "同意接收简历"
        case .rejected: "拒绝或不合适"
        case .question: "需要回复"
        case .greeting: "普通招呼"
        case .unknown: "待判断"
        }
    }
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: String
    var direction: MessageDirection
    var text: String
    var sentAt: Date
    var intent: RecruiterIntent?
    var confidence: Double?
    /// BOSS 服务端消息 ID；本地摘要 ID 不能用作写入授权。
    var remoteMID: String? = nil
    var remoteSenderID: String? = nil
    var remoteRecipientID: String? = nil
    var remoteMessageType: Int? = nil
    var remoteBodyType: Int? = nil
    var remoteActionAID: Int? = nil
    var actionAnnexType: Int? = nil
    var remoteScene: Int? = nil
    var actionWasOperated: Bool? = nil
    var dialogType: Int? = nil
    var dialogWasOperated: Bool? = nil
    /// 仅从 BOSS 对话按钮 URL 解析，不根据文案或 body.action.aid 推断。
    var dialogButtonActionAID: Int? = nil
    var dialogButtonScene: Int? = nil
    /// 出站附件链接的最小凭证；简历令牌仅用于精确匹配，不显示或记录到日志。
    var hyperLinkType: Int? = nil
    var hyperLinkResumeToken: String? = nil
    /// 仅完整消息的收发双方字段可确认方向，未读数推断只用于显示。
    var hasAuthoritativeDirection: Bool? = nil
    /// 仅完整历史可授权简历写入，好友列表摘要必须为 false。
    var isAuthoritativeHistoryRecord: Bool? = nil
    /// 同意文本或动作来自完整历史，不能继承好友摘要中的展示内容。
    var hasAuthoritativeConsentPayload: Bool? = nil

    /// 附件发送的展示证据，不能授权外部写入。
    var showsSentResumeAttachment: Bool {
        if isAuthoritativeHistoryRecord == true, hasAuthoritativeDirection == true,
           direction == .outgoing, remoteBodyType == 12, hyperLinkType == 1,
           hyperLinkResumeToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        let fullHistory = isAuthoritativeHistoryRecord == true && hasAuthoritativeDirection == true
        let summary = isAuthoritativeHistoryRecord == false && direction == .system && remoteMID == nil
        guard (fullHistory || summary), text.contains("附件简历") else { return false }
        let normalized = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
        let sentCard = normalized.hasPrefix("您的附件简历") && normalized.hasSuffix("已发送给boss点击查看附件")
        let viewedCard = normalized == "对方已查看了您的附件简历"
        return (sentCard && (summary || (remoteMessageType == 3 && remoteBodyType == 12))) ||
            (viewedCard && (summary || (remoteMessageType == 4 && remoteBodyType == 1)))
    }

    var resumeAttachmentSentAt: Date? {
        guard showsSentResumeAttachment, sentAt.timeIntervalSince1970 > 0 else { return nil }
        let normalized = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace }
        return normalized == "对方已查看了您的附件简历" ? nil : sentAt
    }

    var displayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasDisplayableText: Bool {
        !displayText.isEmpty
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id: String
    var accountID: UUID
    var remoteConversationID: String? = nil
    var securityID: String? = nil
    var listID: String? = nil
    var encryptedBossID: String? = nil
    var friendSource: String? = nil
    var groupID: String? = nil
    var recruiterName: String
    var company: String
    var jobTitle: String
    var messages: [ChatMessage]
    var unreadCount: Int
    var lastSyncedAt: Date
    var remoteUpdatedAt: Date? = nil
    var sourceURL: String
    var jobSalary: String? = nil
    var jobLocation: String? = nil
    /// 用户最近确认的待处理项；后续来信、待办或投递更新会重新打开会话。
    var handledAt: Date? = nil

    var displayableMessages: [ChatMessage] {
        messages.filter(\.hasDisplayableText)
    }

    var latestMessage: ChatMessage? {
        messages.last(where: \.hasDisplayableText)
    }

    var latestActivityAt: Date {
        if let remoteUpdatedAt, remoteUpdatedAt.timeIntervalSince1970 > 0 {
            return remoteUpdatedAt
        }
        return latestMessage?.sentAt ?? lastSyncedAt
    }
}

struct BossHistorySyncOutcome: Equatable, Sendable {
    var conversationID: String
    var insertedMessageCount: Int
    var insertedIncomingCount: Int
    var refreshedMessageCount: Int
    var ignoredMessageCount: Int
    var newestRemoteMID: String?
    var authoritativeConsentCount: Int

    static func empty(conversationID: String) -> BossHistorySyncOutcome {
        BossHistorySyncOutcome(
            conversationID: conversationID,
            insertedMessageCount: 0,
            insertedIncomingCount: 0,
            refreshedMessageCount: 0,
            ignoredMessageCount: 0,
            newestRemoteMID: nil,
            authoritativeConsentCount: 0
        )
    }
}
