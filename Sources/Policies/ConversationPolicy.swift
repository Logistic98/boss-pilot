import Foundation

struct ConversationDecision: Equatable {
    let intent: RecruiterIntent
    let confidence: Double
    let reason: String
    let suggestedReply: String
    let shouldCreateResumeTask: Bool
}

enum ConversationWorkState: Equatable {
    case pending
    case processed
    case active
    case filtered
}

struct ConversationPolicy {
    private static let rejectionTerms = [
        "不合适", "不匹配", "暂不考虑", "暂时不考虑", "岗位已关闭", "已经招到",
        "停止招聘", "谢谢关注", "先不聊了", "不用发简历", "不可以发简历",
        "不能发简历", "不要发简历", "先别发简历", "暂时别发简历", "无需发简历",
        "不接受简历", "不收简历", "不可以聊", "不能聊", "不方便聊", "不愿意聊",
        "不可以沟通", "不能沟通", "不方便沟通", "不愿意沟通", "暂不沟通"
    ]

    private static let explicitResumeAcceptancePatterns = [
        #"^(?:(?:您好|你好|好的|好)[，,\s]+)?(?:可以|请|麻烦|直接)\s*(?:先|直接)?\s*(?:给我|向我|这边)?\s*(?:发|发送|投递)\s*(?:一?下|一份|1份|这份|份)?\s*(?:你的|您的)?\s*简历(?:给我|过来|来|吧|即可|就可以|就行)?[。！!\s]*$"#,
        #"^(?:(?:您好|你好|好的|好)[，,\s]+)?方便\s*(?:给我|向我|这边)?\s*(?:发|发送|投递)\s*(?:一?下|一份|1份|这份|份)\s*(?:你的|您的)?\s*简历(?:给我|过来|来|吧|即可)?[。！!\s]*$"#,
        #"^(?:(?:您好|你好|好的|好)[，,\s]+)?(?:可以\s*)?(?:请|麻烦)?\s*(?:把|将)\s*(?:你的|您的)?\s*简历\s*(?:发|发送|投递)\s*(?:给我|过来|来|一下)?[。！!\s]*$"#,
        #"^(?:(?:您好|你好|好的|好)[，,\s]+)?(?:发|发送|投递)\s*(?:一?下|一份|1份|这份|份)?\s*(?:你的|您的)?\s*简历(?:给我|过来|来|吧|即可)?[。！!\s]*$"#,
        #"^(?:(?:您好|你好|好的|好)[，,\s]+)?(?:你的|您的)?\s*简历\s*(?:发来|发过来|发送过来)(?:吧|即可)?[。！!\s]*$"#,
        #"^(?:(?:您好|你好|好的|好)[，,\s]+)?(?:我这边|我们|这边|我)?\s*(?:可以|愿意|同意|接受)\s*(?:接收|看|收)?\s*(?:你的|您的)?\s*简历(?:了|吧|过来)?[。！!\s]*$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let explicitConversationAcceptancePatterns = [
        #"^(?:(?:您好|你好|好的|好|嗯嗯)[，,\s]+)?(?:可以|愿意|没问题|行)[，,\s]*(?:和你|跟你|与你|和您|跟您|与您)?\s*(?:进一步)?\s*(?:聊一聊|聊一下|聊聊|沟通一下|沟通)(?:这个岗位|该岗位|岗位)?(?:吧|呀|啊)?[。！!\s]*$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let ambiguousAcceptanceTerms = [
        "?", "？", "请问", "是否", "能否", "可否", "如果", "假如", "不一定",
        "不能", "不可", "不要", "不用", "无需", "不接受", "不收", "不建议",
        "不方便", "没办法", "暂缓", "先别", "暂时", "听说", "据说", "他说",
        "她说", "对方说", "有人说", "转述", "没说", "并非"
    ]

    static func classify(_ text: String) -> ConversationDecision {
        let normalized = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)

        if let term = rejectionTerms.first(where: { normalized.contains($0) }) {
            return ConversationDecision(
                intent: .rejected,
                confidence: 0.98,
                reason: "命中明确拒绝表达“\(term)”",
                suggestedReply: "",
                shouldCreateResumeTask: false
            )
        }

        if containsAcceptanceTopic(normalized),
           ambiguousAcceptanceTerms.contains(where: { normalized.contains($0) }) {
            return ConversationDecision(
                intent: normalized.contains("?") || normalized.contains("？") || normalized.contains("请问") ? .question : .unknown,
                confidence: 0.45,
                reason: "继续沟通或接收简历的表达含否定、疑问或转述语境，需人工确认",
                suggestedReply: "",
                shouldCreateResumeTask: false
            )
        }

        if matchesExplicitResumeAcceptance(normalized) {
            return ConversationDecision(
                intent: .resumeAccepted,
                confidence: 0.94,
                reason: "命中严格限定的明确接收简历句式",
                suggestedReply: "好的，我会通过 BOSS 官方页面发送简历，请您查收，谢谢。",
                shouldCreateResumeTask: true
            )
        }

        if matchesExplicitConversationAcceptance(normalized) {
            return ConversationDecision(
                intent: .resumeAccepted,
                confidence: 0.92,
                reason: "命中严格限定的明确继续沟通句式",
                suggestedReply: "好的，我会通过 BOSS 官方页面发送简历，请您查收，谢谢。",
                shouldCreateResumeTask: true
            )
        }

        if normalized.contains("?") || normalized.contains("？") || normalized.contains("方便") || normalized.contains("请问") {
            return ConversationDecision(
                intent: .question,
                confidence: 0.72,
                reason: "消息包含问题或需要确认的表达",
                suggestedReply: "您好，感谢您的消息。我可以进一步说明相关经历，您想优先了解哪一部分？",
                shouldCreateResumeTask: false
            )
        }

        if normalized.contains("您好") || normalized.contains("你好") {
            return ConversationDecision(
                intent: .greeting,
                confidence: 0.70,
                reason: "识别为普通招呼",
                suggestedReply: "您好，感谢联系。我对该岗位很感兴趣，方便进一步沟通岗位要求吗？",
                shouldCreateResumeTask: false
            )
        }

        return ConversationDecision(
            intent: .unknown,
            confidence: 0.35,
            reason: "缺少足够明确的意图证据",
            suggestedReply: "",
            shouldCreateResumeTask: false
        )
    }

    static func resumeTask(
        for conversation: Conversation,
        latestMessage: ChatMessage,
        existingActions: [PendingAction]
    ) -> PendingAction? {
        let decision = classify(latestMessage.text)
        guard latestMessage.direction == .incoming,
              decision.intent == .resumeAccepted,
              decision.shouldCreateResumeTask,
              decision.confidence >= 0.90 else { return nil }

        let alreadyExists = existingActions.contains {
            $0.accountID == conversation.accountID &&
            $0.conversationID == conversation.id &&
            $0.kind == .sendResume &&
            $0.status != .dismissed &&
            $0.status != .failed
        }
        guard !alreadyExists else { return nil }

        return PendingAction(
            accountID: conversation.accountID,
            conversationID: conversation.id,
            kind: .sendResume,
            content: decision.suggestedReply,
            reason: "招聘方明确同意继续沟通或接收简历。请到 BOSS 官方页面核对会话并手动发送。"
        )
    }

    static func attentionTask(
        for conversation: Conversation,
        latestMessage: ChatMessage,
        existingActions: [PendingAction]
    ) -> PendingAction? {
        let decision = classify(latestMessage.text)
        guard latestMessage.direction == .incoming,
              decision.intent != .rejected,
              decision.intent != .resumeAccepted else { return nil }
        let alreadyExists = existingActions.contains {
            $0.accountID == conversation.accountID &&
            $0.conversationID == conversation.id &&
            $0.kind == .sendMessage &&
            $0.status.requiresAttention
        }
        guard !alreadyExists else { return nil }
        return PendingAction(
            accountID: conversation.accountID,
            conversationID: conversation.id,
            kind: .sendMessage,
            content: decision.suggestedReply,
            reason: decision.intent == .unknown
                ? "招聘方消息意图不明确，需要你在 BOSS 官方聊天中确认。"
                : "招聘方消息值得继续处理：\(decision.reason)。"
        )
    }

    static func displayOrder(
        _ conversations: [Conversation],
        actions: [PendingAction],
        deliveryRecords: [ResumeDeliveryRecord]
    ) -> [(conversation: Conversation, state: ConversationWorkState)] {
        let actionsByConversation = Dictionary(grouping: actions, by: \.conversationID)
        let deliveriesByConversation = Dictionary(grouping: deliveryRecords, by: \.conversationID)
        return conversations.map { conversation in
            (
                conversation: conversation,
                state: workState(
                    for: conversation,
                    actions: actionsByConversation[conversation.id] ?? [],
                    deliveryRecords: deliveriesByConversation[conversation.id] ?? []
                ),
                activityAt: conversation.latestActivityAt
            )
        }.sorted { lhs, rhs in
            if (lhs.state == .pending) != (rhs.state == .pending) { return lhs.state == .pending }
            if lhs.conversation.unreadCount != rhs.conversation.unreadCount {
                return lhs.conversation.unreadCount > rhs.conversation.unreadCount
            }
            if lhs.activityAt != rhs.activityAt { return lhs.activityAt > rhs.activityAt }
            return lhs.conversation.id < rhs.conversation.id
        }.map { (conversation: $0.conversation, state: $0.state) }
    }

    static func workState(
        for conversation: Conversation,
        actions: [PendingAction],
        deliveryRecords: [ResumeDeliveryRecord]
    ) -> ConversationWorkState {
        let matchingActions = actions.filter {
            $0.accountID == conversation.accountID && $0.conversationID == conversation.id
        }
        let matchingDeliveries = deliveryRecords.filter {
            $0.accountID == conversation.accountID && $0.conversationID == conversation.id
        }
        let newestAttention = attentionUpdatedAt(
            for: conversation,
            actions: matchingActions,
            deliveryRecords: matchingDeliveries
        )

        if let newestAttention,
           conversation.handledAt.map({ newestAttention > $0 }) ?? true {
            return .pending
        }

        if let latestIncoming = conversation.messages.last(where: {
            $0.direction == .incoming && $0.hasDisplayableText
        }), classify(latestIncoming.text).intent == .rejected {
            return .filtered
        }

        if conversation.handledAt != nil {
            return .processed
        }
        return .active
    }

    static func attentionUpdatedAt(
        for conversation: Conversation,
        actions: [PendingAction],
        deliveryRecords: [ResumeDeliveryRecord]
    ) -> Date? {
        var dates = actions
            .filter { $0.status.requiresAttention }
            .map(\.createdAt)

        dates.append(contentsOf: deliveryRecords.compactMap { record in
            (!record.state.isTerminal || record.state == .failed) ? record.updatedAt : nil
        })

        if conversation.unreadCount > 0,
           let latestIncoming = conversation.messages.last(where: {
               $0.direction == .incoming && $0.hasDisplayableText
           }), classify(latestIncoming.text).intent != .rejected {
            dates.append(latestIncoming.sentAt)
        }
        return dates.max()
    }

    private static func matchesExplicitResumeAcceptance(_ text: String) -> Bool {
        matches(patterns: explicitResumeAcceptancePatterns, text: text)
    }

    private static func matchesExplicitConversationAcceptance(_ text: String) -> Bool {
        matches(patterns: explicitConversationAcceptancePatterns, text: text)
    }

    private static func containsAcceptanceTopic(_ text: String) -> Bool {
        text.contains("简历") ||
            ["聊一聊", "聊一下", "聊聊", "进一步聊", "沟通"].contains(where: text.contains)
    }

    private static func matches(patterns: [NSRegularExpression], text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { regex in
            return regex.firstMatch(in: text, range: range)?.range == range
        }
    }
}
