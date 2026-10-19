import Foundation
import CoreFoundation
import PDFKit
import WebKit

struct BossResumeAttachment: Sendable, Hashable {
    let resumeToken: String
    let annexType: Int
    let displayName: String?
    let suffixName: String?
    let isRestricted: Bool
}

struct BossSavedResumeAttachment: Sendable, Hashable {
    let resumeToken: String
}

enum BossResumeExchangeWriteState: String, Sendable, Hashable {
    /// BOSS 已接受 type-3 请求，附件仍须招聘方确认后才能发送。
    case requestCreatedAwaitingRecruiter

    /// BOSS 已接受 type-4 操作，尚未通过独立历史回读确认。
    case serverAcceptedUnverified
}

struct BossResumeExchangeWriteResult: Sendable, Hashable {
    let state: BossResumeExchangeWriteState
    let serverStatus: Int
    let alertType: Int?
}

/// 不联网的协议夹具，仅含合成数据，用于验证请求构造且不暴露账号令牌。
enum BossResumeExchangeProtocolBodyKind: String, Sendable, Hashable {
    case none
    case formURLEncoded
    case JSON
    case PDFMultipart
}

enum BossResumeExchangeProtocolResponseState: String, Sendable, Hashable {
    case warmupNavigation
    case payload
    case statusPreflight
    case requestCreatedAwaitingRecruiter
    case serverAcceptedUnverified
}

struct BossResumeExchangeProtocolField: Sendable, Hashable {
    let name: String
    let value: String?
}

struct BossResumeExchangeProtocolInspection: Sendable, Hashable {
    let endpointPath: String
    let method: String
    let absoluteURL: String
    let queryItems: [BossResumeExchangeProtocolField]
    let bodyKind: BossResumeExchangeProtocolBodyKind
    let bodyFields: [BossResumeExchangeProtocolField]
    let bodyText: String?
    let contentType: String?
    let writeMayHaveCommitted: Bool
    let responseState: BossResumeExchangeProtocolResponseState
}

/// 协议夹具不联网；生命周期验证使用隔离且禁网的 WebKit 页面。
enum BossResumeExchangeProtocolSelfCheck {
    @MainActor
    static func verifyJavaScriptLifecycle() async throws {
        try await BossResumeExchangeProfileClient.verifyJavaScriptLifecycle()
    }

    static func inspections() throws -> [BossResumeExchangeProtocolInspection] {
        let warmupURL = try BossResumeOfficialRequest.warmupURL()
        let warmup = BossResumeExchangeProtocolInspection(
            endpointPath: BossResumeOfficialEndpoint.warmup.path,
            method: "GET",
            absoluteURL: warmupURL.absoluteString,
            queryItems: [],
            bodyKind: .none,
            bodyFields: [],
            bodyText: nil,
            contentType: nil,
            writeMayHaveCommitted: BossResumeOfficialEndpoint.warmup.isWrite,
            responseState: BossResumeOfficialEndpoint.warmup.responseState
        )
        let individualHistoryQuery = BossResumeHistoryQuery(
            bossID: "selfcheck-boss-id",
            maximumMessageID: "0",
            count: 20,
            page: 1,
            source: 0,
            securityID: "selfcheck-security-id"
        )
        let groupHistoryQuery = BossResumeHistoryQuery(
            bossID: "",
            groupID: "selfcheck-group-id",
            maximumMessageID: "0",
            count: 20,
            page: 1,
            source: 0,
            securityID: "",
            gid: "selfcheck-group-id"
        )
        let requests: [BossResumeOfficialRequest] = [
            try .listAttachments(from: 2),
            try .listAttachments(from: 3),
            try .uploadPDF(data: Data("selfcheck-pdf".utf8), fileName: "resume.pdf"),
            try .saveAttachment(previewURL: "selfcheck-preview-token", from: 8),
            try .testRequest(securityID: "selfcheck-security-id", friendSource: 0),
            try .requestExchange(
                securityID: "selfcheck-security-id",
                resumeToken: "selfcheck-resume-token"
            ),
            try .testAccept(
                securityID: "selfcheck-security-id",
                messageID: "123456789"
            ),
            try .acceptExchange(
                securityID: "selfcheck-security-id",
                messageID: "123456789",
                resumeToken: "selfcheck-resume-token",
                scene: 1
            ),
            try .history(query: individualHistoryQuery),
            try .history(query: groupHistoryQuery),
            try .friendSummaries(friendIDs: ["selfcheck-friend-id"], directFriendIDs: [])
        ]
        return [warmup] + requests.map(\.protocolInspection)
    }

    static func isStructurallyValidPDF(_ data: Data) -> Bool {
        BossResumePDFValidation.isStructurallyValid(data)
    }
}

struct BossResumeHistoryQuery: Sendable, Hashable {
    let bossID: String
    let groupID: String?
    let maximumMessageID: String
    let count: Int
    let page: Int
    let source: Int
    let securityID: String
    let gid: String?

    init(
        bossID: String,
        groupID: String? = nil,
        maximumMessageID: String,
        count: Int = 20,
        page: Int = 1,
        source: Int,
        securityID: String,
        gid: String? = nil
    ) {
        self.bossID = bossID
        self.groupID = groupID
        self.maximumMessageID = maximumMessageID
        self.count = count
        self.page = page
        self.source = source
        self.securityID = securityID
        self.gid = gid
    }
}

/// 只传输规范化、去控制字符且限长的文本，不含 Cookie 或原始动作扩展，也不记录到日志。
struct BossResumeHistoryMessage: Sendable, Hashable {
    let messageID: String
    let timestampMilliseconds: Int64?
    let messageType: Int?
    let bodyType: Int?
    let sanitizedText: String?
    let senderID: String?
    let recipientID: String?
    let isSelf: Bool?
    let actionID: Int?
    let actionAnnexType: Int?
    let actionScene: Int?
    let actionWasOperated: Bool?
    let dialogType: Int?
    let dialogWasOperated: Bool?
    var dialogButtonActionAID: Int? = nil
    var dialogButtonScene: Int? = nil
    var hyperLinkType: Int? = nil
    var hyperLinkResumeToken: String? = nil
}

struct BossResumeHistoryPage: Sendable, Hashable {
    let messages: [BossResumeHistoryMessage]
    let hasMore: Bool
    let minimumMessageID: String?
    /// 历史 fromId/toId 使用的数字 geek UID，与资料接口的加密身份不同。
    let currentUserID: String?
}

struct BossGreetingDeliveryReceipt: Sendable, Hashable {
    let messageID: String
    let deliveredAt: Date
    let recruiterName: String
}

/// 开聊成功须在权威历史中找到正文一致且 MID 更新的出站消息，建立好友或 WebSocket 提交成功均不足以确认。
enum BossGreetingDeliveryPolicy {
    static func confirmedMessage(
        in messages: [BossResumeHistoryMessage],
        text: String,
        currentUserID: String,
        newerThanMessageID baseline: UInt64?
    ) -> BossResumeHistoryMessage? {
        messages
            .filter { message in
                guard message.isSelf != false,
                      message.senderID == currentUserID,
                      message.recipientID?.isEmpty == false,
                      message.recipientID != currentUserID,
                      message.sanitizedText == text,
                      let messageID = positiveMessageID(message.messageID) else {
                    return false
                }
                return baseline.map { messageID > $0 } ?? true
            }
            .max {
                (positiveMessageID($0.messageID) ?? 0) <
                    (positiveMessageID($1.messageID) ?? 0)
            }
    }

    static func positiveMessageID(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let parsed = UInt64(value), parsed > 0 else { return nil }
        return parsed
    }
}

private struct BossGreetingConversationContext: Sendable, Hashable {
    let recruiterName: String
    let friendID: String
    let encryptedBossID: String
    let remoteJobID: String
    let securityID: String
    let friendSource: Int
    let currentUserID: String
}

/// 绑定实际 type-3 路由的只读预检结果；限制构造入口，防止调用方伪造。
struct BossResumeRequestPreflight: Sendable, Hashable {
    fileprivate let profileID: UUID
    fileprivate let securityID: String
    fileprivate let friendSource: Int
}

/// 绑定原生请求 MID 的只读 type-4 预检结果。
struct BossResumeAcceptPreflight: Sendable, Hashable {
    fileprivate let profileID: UUID
    fileprivate let securityID: String
    fileprivate let requestMessageID: String
}

enum BossResumeExchangeError: Error, LocalizedError, Sendable, Equatable {
    case invalidParameter(String)
    case authorizationChanged
    case unauthenticated
    case invalidPDF
    case PDFTooLarge(maximumBytes: Int)
    case fileReadFailed
    case endpointNotAllowed
    case serviceInvalidated
    case navigationFailed
    case navigationTimedOut
    case bridgeEvaluationFailed
    case bridgeTransportFailed
    case responseTooLarge
    case requestTimedOut(endpoint: String, writeMayHaveCommitted: Bool)
    case invalidResponse(endpoint: String)
    case conversationStoreUnavailable
    case greetingConversationUnavailable
    case greetingConversationMismatch
    case greetingWebSocketUnavailable
    case greetingDeliveryUnconfirmed
    case httpStatus(endpoint: String, status: Int, writeMayHaveCommitted: Bool)
    case APIError(endpoint: String, code: Int, writeMayHaveCommitted: Bool)
    case businessStatus(endpoint: String, status: Int, writeMayHaveCommitted: Bool)
    case restrictedAttachment

    var errorDescription: String? {
        switch self {
        case .invalidParameter(let name):
            "BOSS 附件简历请求参数无效：\(name)。"
        case .authorizationChanged:
            "账号、附件或自动发送权限已变化，未执行 BOSS 写请求。"
        case .unauthenticated:
            "该 BOSS 账号尚未登录或登录已失效。"
        case .invalidPDF:
            "附件必须是有效的 PDF 文件。"
        case .PDFTooLarge(let maximumBytes):
            "PDF 文件过大，最大允许 \(maximumBytes / 1_048_576) MB。"
        case .fileReadFailed:
            "无法读取所选 PDF 文件。"
        case .endpointNotAllowed:
            "请求地址不在 BOSS 附件简历协议白名单内。"
        case .serviceInvalidated:
            "该 BOSS 账号的附件简历会话已关闭。"
        case .navigationFailed:
            "BOSS 官方会话页面加载失败。"
        case .navigationTimedOut:
            "BOSS 官方会话页面准备超时。"
        case .bridgeEvaluationFailed:
            "无法在 BOSS 官方会话中执行请求。"
        case .bridgeTransportFailed:
            "BOSS 官方会话请求未完成。"
        case .responseTooLarge:
            "BOSS 官方接口返回的数据超过安全上限。"
        case .requestTimedOut(let endpoint, let writeMayHaveCommitted):
            writeMayHaveCommitted
                ? "BOSS 写请求超时（\(endpoint)）；服务端可能已经处理，禁止自动重试。"
                : "BOSS 请求超时（\(endpoint)）。"
        case .invalidResponse(let endpoint):
            "BOSS 接口返回格式无效（\(endpoint)）。"
        case .conversationStoreUnavailable:
            "BOSS 消息页尚未准备好沟通列表。"
        case .greetingConversationUnavailable:
            "BOSS 消息页尚未准备好目标会话。"
        case .greetingConversationMismatch:
            "BOSS 当前会话与本次待发送岗位不一致，已阻止发送。"
        case .greetingWebSocketUnavailable:
            "BOSS 站内消息连接尚未就绪。"
        case .greetingDeliveryUnconfirmed:
            "BOSS 未在完整消息历史中返回已送达的招呼语。"
        case .httpStatus(let endpoint, let status, let writeMayHaveCommitted):
            writeMayHaveCommitted
                ? "BOSS 写请求返回 HTTP \(status)（\(endpoint)）；结果未验证，禁止自动重试。"
                : "BOSS 请求返回 HTTP \(status)（\(endpoint)）。"
        case .APIError(let endpoint, let code, let writeMayHaveCommitted):
            writeMayHaveCommitted
                ? "BOSS 写请求返回业务码 \(code)（\(endpoint)）；结果未验证，禁止自动重试。"
                : "BOSS 请求返回业务码 \(code)（\(endpoint)）。"
        case .businessStatus(let endpoint, let status, let writeMayHaveCommitted):
            writeMayHaveCommitted
                ? "BOSS 写请求返回状态 \(status)（\(endpoint)）；结果未验证，禁止自动重试。"
                : "BOSS 请求返回状态 \(status)（\(endpoint)）。"
        case .restrictedAttachment:
            "该附件被 BOSS 标记为受限，不能发送。"
        }
    }
}

/// 同源 WebKit 简历交换客户端；每个 Profile 独立持有视图并串行操作，写入不自动重试。
@MainActor
final class BossResumeExchangeService {
    static let shared = BossResumeExchangeService()

    private var clients: [UUID: BossResumeExchangeProfileClient] = [:]

    func listAttachments(profileID: UUID, from: Int) async throws -> [BossResumeAttachment] {
        try validateFrom(from)
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.listAttachments(from: from)
            let data = try await client.perform(request)
            let payload = try Self.validatedPayload(data, endpoint: request.endpoint)
            guard let rawList = payload["resumeList"] as? [Any] else {
                throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
            }

            return try rawList.map { item in
                guard let dictionary = item as? [String: Any] else {
                    throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
                }
                guard let token = Self.nonemptyString(dictionary["resumeId"])
                        ?? Self.nonemptyString(dictionary["encryptId"]),
                      let annexType = Self.integer(dictionary["annexType"]),
                      let isRestricted = Self.boolean(dictionary["restricted"]) else {
                    throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
                }
                return BossResumeAttachment(
                    resumeToken: token,
                    annexType: annexType,
                    displayName: Self.nonemptyString(dictionary["showName"])
                        ?? Self.nonemptyString(dictionary["customName"])
                        ?? Self.nonemptyString(dictionary["originalName"]),
                    suffixName: Self.nonemptyString(dictionary["suffixName"]),
                    isRestricted: isRestricted
                )
            }
        }
    }

    /// 上传 PDF 时由 WebKit 生成 multipart 边界，不手动设置缺少边界的 Content-Type。
    func uploadPDF(
        profileID: UUID,
        fileURL: URL,
        commitIsStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> String {
        let upload = try await Task.detached(priority: .utility) {
            try Self.readPDF(at: fileURL)
        }.value
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.uploadPDF(
                data: upload.data,
                fileName: upload.fileName
            )
            let data = try await client.perform(
                request,
                commitIsStillAuthorized: commitIsStillAuthorized
            )
            let payload = try Self.validatedPayload(data, endpoint: request.endpoint)
            guard let previewURL = Self.nonemptyString(payload["previewUrl"]) else {
                throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
            }
            return previewURL
        }
    }

    /// 将预览令牌保存为 annexType=0 附件，返回交换接口所需的加密简历令牌。
    func saveUploadedAttachment(
        profileID: UUID,
        previewURL: String,
        from: Int = 8,
        commitIsStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> BossSavedResumeAttachment {
        try validateFrom(from)
        try Self.validateOpaqueValue(previewURL, name: "previewUrl", maximumLength: 4_096)
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.saveAttachment(
                previewURL: previewURL,
                from: from
            )
            let data = try await client.perform(
                request,
                commitIsStillAuthorized: commitIsStillAuthorized
            )
            let payload = try Self.validatedPayload(data, endpoint: request.endpoint)
            guard let resumeToken = Self.nonemptyString(payload["resumeId"]) else {
                throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
            }
            return BossSavedResumeAttachment(resumeToken: resumeToken)
        }
    }

    /// 附件上传或保存前执行只读 type-3 预检，避免拒绝时留下附件或消耗同意许可。
    func preflightRequestAttachmentResume(
        profileID: UUID,
        securityID: String,
        friendSource: Int
    ) async throws -> BossResumeRequestPreflight {
        try Self.validateOpaqueValue(securityID, name: "securityId")
        guard friendSource >= 0 else {
            throw BossResumeExchangeError.invalidParameter("friendSource")
        }
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.testRequest(
                securityID: securityID,
                friendSource: friendSource
            )
            let data = try await client.perform(request)
            _ = try Self.validatedStatusPayload(data, endpoint: request.endpoint)
            return BossResumeRequestPreflight(
                profileID: profileID,
                securityID: securityID,
                friendSource: friendSource
            )
        }
    }

    /// 使用预检结果创建 type-3 请求；成功仅表示请求已创建，不表示附件已发送。
    func requestAttachmentResume(
        preflight: BossResumeRequestPreflight,
        resumeToken: String,
        commitIsStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> BossResumeExchangeWriteResult {
        try Self.validateOpaqueValue(resumeToken, name: "encryptResumeId")
        let client = client(for: preflight.profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.requestExchange(
                securityID: preflight.securityID,
                resumeToken: resumeToken
            )
            let data = try await client.perform(
                request,
                commitIsStillAuthorized: commitIsStillAuthorized
            )
            let payload = try Self.validatedStatusPayload(data, endpoint: request.endpoint)
            return BossResumeExchangeWriteResult(
                state: .requestCreatedAwaitingRecruiter,
                serverStatus: 0,
                alertType: Self.integer(payload["alertType"])
            )
        }
    }

    /// 附件写入前独立执行原生卡片只读预检。
    func preflightAcceptAttachmentResume(
        profileID: UUID,
        securityID: String,
        requestMessageID: String
    ) async throws -> BossResumeAcceptPreflight {
        try Self.validateOpaqueValue(securityID, name: "securityId")
        try Self.validateMessageID(requestMessageID, name: "mid")
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.testAccept(
                securityID: securityID,
                messageID: requestMessageID
            )
            let data = try await client.perform(request)
            _ = try Self.validatedStatusPayload(data, endpoint: request.endpoint)
            return BossResumeAcceptPreflight(
                profileID: profileID,
                securityID: securityID,
                requestMessageID: requestMessageID
            )
        }
    }

    /// 使用预检结果执行 type-4 接受操作；status=0 后仍需回读确认。
    func acceptAttachmentResume(
        preflight: BossResumeAcceptPreflight,
        resumeToken: String,
        scene: Int? = nil,
        commitIsStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> BossResumeExchangeWriteResult {
        try Self.validateOpaqueValue(resumeToken, name: "encryptResumeId")
        if let scene, scene < 0 {
            throw BossResumeExchangeError.invalidParameter("scene")
        }

        let client = client(for: preflight.profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.acceptExchange(
                securityID: preflight.securityID,
                messageID: preflight.requestMessageID,
                resumeToken: resumeToken,
                scene: scene
            )
            let data = try await client.perform(
                request,
                commitIsStillAuthorized: commitIsStillAuthorized
            )
            let payload = try Self.validatedStatusPayload(data, endpoint: request.endpoint)
            return BossResumeExchangeWriteResult(
                state: .serverAcceptedUnverified,
                serverStatus: 0,
                alertType: Self.integer(payload["alertType"])
            )
        }
    }

    func history(
        profileID: UUID,
        query: BossResumeHistoryQuery
    ) async throws -> BossResumeHistoryPage {
        try Self.validateHistoryQuery(query)
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.history(query: query)
            let data = try await client.perform(request)
            let payload = try Self.validatedPayload(data, endpoint: request.endpoint)
            guard let rawMessages = payload["messages"] as? [Any] else {
                throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
            }
            let messages = try rawMessages.map { rawMessage in
                try Self.historyMessage(from: rawMessage, endpoint: request.endpoint)
            }
            return BossResumeHistoryPage(
                messages: messages,
                hasMore: Self.boolean(payload["hasMore"]) ?? false,
                minimumMessageID: Self.nonemptyString(payload["minMsgId"]),
                currentUserID: try await client.authenticatedCurrentUserID()
            )
        }
    }

    /// 通过账号页面的聊天 WebSocket 发送一次，再以服务端历史确认；friend/add 成功不代表消息送达。
    func sendGreetingAndConfirm(
        profileID: UUID,
        expectedSecurityID: String,
        expectedJobID: String,
        text: String,
        commitIsStillAuthorized: @escaping @MainActor () -> Bool,
        markWriteStarted: @escaping @MainActor () throws -> Void
    ) async throws -> BossGreetingDeliveryReceipt {
        try Self.validateOpaqueValue(expectedSecurityID, name: "securityId")
        try Self.validateOpaqueValue(expectedJobID, name: "jobId")
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty, normalizedText.utf8.count <= 4_000 else {
            throw BossResumeExchangeError.invalidParameter("greetingText")
        }

        let client = client(for: profileID)
        return try await client.serialized {
            let context = try await client.waitForGreetingConversation(
                expectedSecurityID: expectedSecurityID,
                expectedJobID: expectedJobID
            )
            let query = BossResumeHistoryQuery(
                bossID: context.encryptedBossID,
                maximumMessageID: "0",
                count: 20,
                page: 1,
                source: context.friendSource,
                securityID: context.securityID
            )
            let baseline = try await Self.readHistoryPage(client: client, query: query)
            if let existing = BossGreetingDeliveryPolicy.confirmedMessage(
                in: baseline.messages,
                text: normalizedText,
                currentUserID: context.currentUserID,
                newerThanMessageID: nil
            ) {
                return BossGreetingDeliveryReceipt(
                    messageID: existing.messageID,
                    deliveredAt: Self.messageDate(existing),
                    recruiterName: context.recruiterName
                )
            }

            guard commitIsStillAuthorized() else {
                throw BossResumeExchangeError.authorizationChanged
            }
            let baselineMID = baseline.messages.compactMap {
                BossGreetingDeliveryPolicy.positiveMessageID($0.messageID)
            }.max()
            try await BossNetworkPacingGate.shared.wait(
                isWrite: true,
                discriminator: "greeting-websocket|\(profileID.uuidString)",
                isStillValid: { await !client.isInvalidated }
            )
            guard commitIsStillAuthorized() else {
                throw BossResumeExchangeError.authorizationChanged
            }
            try markWriteStarted()
            try await client.sendGreeting(
                context: context,
                text: normalizedText
            )

            for attempt in 0..<15 {
                try Task.checkCancellation()
                if attempt > 0 {
                    try await Task.sleep(for: .seconds(2))
                }
                let page = try await Self.readHistoryPage(client: client, query: query)
                if let confirmed = BossGreetingDeliveryPolicy.confirmedMessage(
                    in: page.messages,
                    text: normalizedText,
                    currentUserID: context.currentUserID,
                    newerThanMessageID: baselineMID
                ) {
                    return BossGreetingDeliveryReceipt(
                        messageID: confirmed.messageID,
                        deliveredAt: Self.messageDate(confirmed),
                        recruiterName: context.recruiterName
                    )
                }
            }
            throw BossResumeExchangeError.greetingDeliveryUnconfirmed
        }
    }

    /// 已跨过写入边界却丢失 JavaScript 回调时，仅回读核对，不再次发送。
    func confirmGreetingDelivery(
        profileID: UUID,
        expectedSecurityID: String,
        expectedJobID: String,
        text: String,
        writeStartedAt: Date
    ) async throws -> BossGreetingDeliveryReceipt {
        try Self.validateOpaqueValue(expectedSecurityID, name: "securityId")
        try Self.validateOpaqueValue(expectedJobID, name: "jobId")
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw BossResumeExchangeError.invalidParameter("greetingText")
        }
        let earliestAcceptedDate = writeStartedAt.addingTimeInterval(-60)
        let client = client(for: profileID)
        return try await client.serialized {
            let context = try await client.waitForGreetingConversation(
                expectedSecurityID: expectedSecurityID,
                expectedJobID: expectedJobID
            )
            let query = BossResumeHistoryQuery(
                bossID: context.encryptedBossID,
                maximumMessageID: "0",
                count: 20,
                page: 1,
                source: context.friendSource,
                securityID: context.securityID
            )
            var lastMessages: [BossResumeHistoryMessage] = []
            for attempt in 0..<15 {
                try Task.checkCancellation()
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                let page = try await Self.readHistoryPage(client: client, query: query)
                lastMessages = page.messages
                if let confirmed = BossGreetingDeliveryPolicy.confirmedMessage(
                    in: page.messages.filter { Self.messageDate($0) >= earliestAcceptedDate },
                    text: normalizedText,
                    currentUserID: context.currentUserID,
                    newerThanMessageID: nil
                ) {
                    return BossGreetingDeliveryReceipt(
                        messageID: confirmed.messageID,
                        deliveredAt: Self.messageDate(confirmed),
                        recruiterName: context.recruiterName
                    )
                }
            }
            let diagnostic = Self.greetingHistoryDiagnostic(
                messages: lastMessages,
                currentUserID: context.currentUserID,
                text: normalizedText
            )
            fputs("BOSS GREETING HISTORY STATE: \(diagnostic)\n", stderr)
            throw BossResumeExchangeError.greetingDeliveryUnconfirmed
        }
    }

    /// 仅补全聊天中已知好友 ID，不枚举会话或记录会话正文。
    func friendSummariesRaw(
        profileID: UUID,
        friendIDs: [String],
        directFriendIDs: [String] = []
    ) async throws -> Data {
        let client = client(for: profileID)
        return try await client.serialized {
            let request = try BossResumeOfficialRequest.friendSummaries(
                friendIDs: friendIDs,
                directFriendIDs: directFriendIDs
            )
            let data = try await client.perform(request)
            _ = try Self.validatedPayload(data, endpoint: request.endpoint)
            return data
        }
    }

    /// 从官方消息页枚举已加载的会话；好友补全接口不能以空 ID 冒充全量列表。
    func pageConversationSummaries(profileID: UUID) async throws -> [BossFriendSummary] {
        let client = client(for: profileID)
        return try await client.serialized {
            let payload = try await client.pageConversationStorePayload()
            return try BossPayloadParser.validatedFriendSummaries(from: payload)
        }
    }

    func forget(profileID: UUID) {
        clients.removeValue(forKey: profileID)?.invalidate()
    }

    private init() {}

    private static func readHistoryPage(
        client: BossResumeExchangeProfileClient,
        query: BossResumeHistoryQuery
    ) async throws -> BossResumeHistoryPage {
        let request = try BossResumeOfficialRequest.history(query: query)
        let data = try await client.perform(request)
        let payload = try validatedPayload(data, endpoint: request.endpoint)
        guard let rawMessages = payload["messages"] as? [Any] else {
            throw BossResumeExchangeError.invalidResponse(endpoint: request.endpoint.path)
        }
        return BossResumeHistoryPage(
            messages: try rawMessages.map {
                try historyMessage(from: $0, endpoint: request.endpoint)
            },
            hasMore: boolean(payload["hasMore"]) ?? false,
            minimumMessageID: nonemptyString(payload["minMsgId"]),
            currentUserID: try await client.authenticatedCurrentUserID()
        )
    }

    private static func messageDate(_ message: BossResumeHistoryMessage) -> Date {
        guard let milliseconds = message.timestampMilliseconds, milliseconds > 0 else {
            return Date()
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func greetingHistoryDiagnostic(
        messages: [BossResumeHistoryMessage],
        currentUserID: String,
        text: String
    ) -> String {
        let details = messages.prefix(20).map { message in
            let byteCount = message.sanitizedText?.utf8.count ?? 0
            return [
                "mid=\(message.messageID)",
                "self=\(message.isSelf.map(String.init(describing:)) ?? "nil")",
                "senderMatches=\(message.senderID == currentUserID)",
                "body=\(message.bodyType.map(String.init) ?? "nil")",
                "textBytes=\(byteCount)",
                "exact=\(message.sanitizedText == text)"
            ].joined(separator: ",")
        }
        return "count=\(messages.count) [\(details.joined(separator: "; "))]"
    }

    private func client(for profileID: UUID) -> BossResumeExchangeProfileClient {
        if let existing = clients[profileID] { return existing }
        let created = BossResumeExchangeProfileClient(profileID: profileID)
        clients[profileID] = created
        return created
    }

    private func validateFrom(_ from: Int) throws {
        guard (0...64).contains(from) else {
            throw BossResumeExchangeError.invalidParameter("from")
        }
    }

    private static func validatedPayload(
        _ data: Data,
        endpoint: BossResumeOfficialEndpoint
    ) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"]) else {
            throw BossResumeExchangeError.invalidResponse(endpoint: endpoint.path)
        }
        guard code != 7 else {
            throw BossResumeExchangeError.unauthenticated
        }
        guard code == 0 else {
            throw BossResumeExchangeError.APIError(
                endpoint: endpoint.path,
                code: code,
                writeMayHaveCommitted: endpoint.isWrite
            )
        }
        if let rootStatus = integer(root["status"]), rootStatus != 0 {
            throw BossResumeExchangeError.businessStatus(
                endpoint: endpoint.path,
                status: rootStatus,
                writeMayHaveCommitted: endpoint.isWrite
            )
        }
        guard let payload = root["zpData"] as? [String: Any] else {
            throw BossResumeExchangeError.invalidResponse(endpoint: endpoint.path)
        }
        return payload
    }

    private static func validatedStatusPayload(
        _ data: Data,
        endpoint: BossResumeOfficialEndpoint
    ) throws -> [String: Any] {
        let payload = try validatedPayload(data, endpoint: endpoint)
        guard let status = integer(payload["status"]) else {
            throw BossResumeExchangeError.invalidResponse(endpoint: endpoint.path)
        }
        guard status == 0 else {
            throw BossResumeExchangeError.businessStatus(
                endpoint: endpoint.path,
                status: status,
                writeMayHaveCommitted: endpoint.isWrite
            )
        }
        return payload
    }

    private static func historyMessage(
        from rawValue: Any,
        endpoint: BossResumeOfficialEndpoint
    ) throws -> BossResumeHistoryMessage {
        guard let dictionary = rawValue as? [String: Any],
              let messageID = nonemptyString(dictionary["mid"]) else {
            throw BossResumeExchangeError.invalidResponse(endpoint: endpoint.path)
        }

        let body = dictionary["body"] as? [String: Any]
        let action = body?["action"] as? [String: Any]
        let dialog = body?["dialog"] as? [String: Any]
        let dialogButton = dialogButtonMetadata(dialog)
        let hyperLink = hyperLinkMetadata(body)
        let sender = dictionary["from"] as? [String: Any]
        let recipient = dictionary["to"] as? [String: Any]
        var annexType: Int?
        var extensionScene: Int?
        var extensionOperated: Bool?
        if let rawExtension = action?["extend"] as? String,
           rawExtension.utf8.count <= 4_096,
           let extensionData = rawExtension.data(using: .utf8),
           let extensionObject = try? JSONSerialization.jsonObject(with: extensionData) as? [String: Any] {
            annexType = integer(extensionObject["annexType"])
            extensionScene = integer(extensionObject["scene"])
            extensionOperated = boolean(extensionObject["operated"])
        }

        return BossResumeHistoryMessage(
            messageID: messageID,
            timestampMilliseconds: int64(dictionary["time"]),
            messageType: integer(dictionary["type"]),
            bodyType: integer(body?["type"]),
            sanitizedText: historyText(dictionary: dictionary, body: body, dialog: dialog),
            senderID: nonemptyString(dictionary["fromId"])
                ?? nonemptyString(dictionary["senderId"])
                ?? nonemptyString(sender?["uid"]),
            recipientID: nonemptyString(dictionary["toId"])
                ?? nonemptyString(dictionary["recipientId"])
                ?? nonemptyString(dictionary["targetId"])
                ?? nonemptyString(recipient?["uid"]),
            isSelf: boolean(dictionary["isSelf"]),
            actionID: integer(action?["aid"]),
            actionAnnexType: annexType,
            actionScene: integer(action?["scene"]) ?? extensionScene,
            actionWasOperated: boolean(action?["operated"]) ?? extensionOperated,
            dialogType: integer(dialog?["type"]),
            dialogWasOperated: boolean(dialog?["operated"]),
            dialogButtonActionAID: dialogButton?.aid,
            dialogButtonScene: dialogButton?.scene,
            hyperLinkType: hyperLink?.type,
            hyperLinkResumeToken: hyperLink?.resumeToken
        )
    }

    /// 仅接受唯一的 aid=38 对话按钮，多个候选时拒绝推断。
    private static func dialogButtonMetadata(
        _ dialog: [String: Any]?
    ) -> (aid: Int, scene: Int?)? {
        guard let dialog else { return nil }
        let containerKeys = ["buttons", "buttonList", "btns", "button"]
        let containers = containerKeys.compactMap { dialog[$0] }
        let URLs = containers.flatMap { destinationURLs(in: $0, depth: 0) }
        let matches = URLs.compactMap { destination -> (aid: Int, scene: Int?)? in
            guard strictQueryInteger(named: "aid", in: destination) == 38 else { return nil }
            return (38, strictQueryInteger(named: "scene", in: destination))
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// 从附件链接提取最小发送凭证，重复或无效的 encryptResumeId 均拒绝。
    private static func hyperLinkMetadata(
        _ body: [String: Any]?
    ) -> (type: Int, resumeToken: String)? {
        guard let body else { return nil }
        let candidates = [body["hyperLink"], body["hyperlink"], body["hyper_link"]]
            .compactMap { $0 as? [String: Any] }
        guard candidates.count == 1,
              let type = integer(candidates[0]["hyperLinkType"])
                ?? integer(candidates[0]["type"]) else { return nil }
        let URLs = destinationURLs(in: candidates[0], depth: 0)
        guard URLs.count == 1,
              let resumeToken = strictResumeToken(in: URLs[0]) else { return nil }
        return (type, resumeToken)
    }

    private static func destinationURLs(in value: Any, depth: Int) -> [String] {
        guard depth <= 4 else { return [] }
        if let dictionary = value as? [String: Any] {
            var result: [String] = []
            for (key, nested) in dictionary {
                let normalizedKey = key.lowercased()
                if ["url", "actionurl", "jumpurl", "redirecturl", "schema", "scheme", "link"]
                    .contains(normalizedKey),
                   let URL = nested as? String,
                   URL.utf8.count <= 4_096 {
                    result.append(URL)
                } else if nested is [String: Any] || nested is [Any] {
                    result.append(contentsOf: destinationURLs(in: nested, depth: depth + 1))
                }
            }
            return result
        }
        if let array = value as? [Any], array.count <= 64 {
            return array.flatMap { destinationURLs(in: $0, depth: depth + 1) }
        }
        return []
    }

    private static func strictQueryInteger(named name: String, in URLString: String) -> Int? {
        guard let value = strictQueryValue(named: name, in: URLString) else { return nil }
        return Int(value)
    }

    /// 仅接受直接令牌或一层唯一 url 参数；混合、重复或更深嵌套均拒绝。
    private static func strictResumeToken(in URLString: String) -> String? {
        let directCount = queryItemCount(named: "encryptResumeId", in: URLString)
        let nestedURLCount = queryItemCount(named: "url", in: URLString)
        guard directCount <= 1, nestedURLCount <= 1 else { return nil }
        let direct = strictQueryValue(named: "encryptResumeId", in: URLString)
        let nestedURL = strictQueryValue(named: "url", in: URLString)
        if let nestedURL {
            guard directCount == 0,
                  queryItemCount(named: "url", in: nestedURL) == 0,
                  queryItemCount(named: "encryptResumeId", in: nestedURL) == 1 else { return nil }
            return strictQueryValue(named: "encryptResumeId", in: nestedURL)
        }
        guard nestedURLCount == 0, directCount == 1 else { return nil }
        return direct
    }

    private static func queryItemCount(named name: String, in URLString: String) -> Int {
        guard let components = URLComponents(string: URLString) else { return 0 }
        return (components.queryItems ?? []).filter { $0.name == name }.count
    }

    private static func strictQueryValue(named name: String, in URLString: String) -> String? {
        guard let components = URLComponents(string: URLString) else { return nil }
        let values = (components.queryItems ?? []).compactMap { item -> String? in
            guard item.name == name,
                  let value = item.value,
                  !value.isEmpty,
                  value.utf8.count <= 4_096 else { return nil }
            return value
        }
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func historyText(
        dictionary: [String: Any],
        body: [String: Any]?,
        dialog: [String: Any]?
    ) -> String? {
        let notify = body?["notify"] as? [String: Any]
        let candidates: [Any?] = [
            body?["text"],
            body?["content"],
            dialog?["text"],
            dialog?["content"],
            dictionary["text"],
            dictionary["content"],
            dictionary["pushText"],
            notify?["text"],
            dictionary["body"] as? String
        ]
        for candidate in candidates {
            guard let rawText = candidate as? String,
                  let sanitized = sanitizedHistoryText(rawText) else { continue }
            return sanitized
        }
        return nil
    }

    private static func sanitizedHistoryText(_ rawText: String) -> String? {
        let normalized = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let scalars = normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(4_096))
    }

    nonisolated private static func readPDF(
        at fileURL: URL
    ) throws -> (data: Data, fileName: String) {
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "pdf" else {
            throw BossResumeExchangeError.invalidPDF
        }
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }

        let maximumBytes = 20 * 1_048_576
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw BossResumeExchangeError.invalidPDF
            }
            if let fileSize = values.fileSize, fileSize > maximumBytes {
                throw BossResumeExchangeError.PDFTooLarge(maximumBytes: maximumBytes)
            }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard !data.isEmpty, data.count <= maximumBytes,
                  BossResumePDFValidation.isStructurallyValid(data) else {
                throw BossResumeExchangeError.invalidPDF
            }
            let fileName = fileURL.lastPathComponent
            guard !fileName.isEmpty, fileName.utf8.count <= 255 else {
                throw BossResumeExchangeError.invalidParameter("fileName")
            }
            return (data, fileName)
        } catch let error as BossResumeExchangeError {
            throw error
        } catch {
            throw BossResumeExchangeError.fileReadFailed
        }
    }

    private static func validateOpaqueValue(
        _ value: String,
        name: String,
        maximumLength: Int = 1_024
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              value.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BossResumeExchangeError.invalidParameter(name)
        }
    }

    private static func validateMessageID(_ value: String, name: String) throws {
        try validateOpaqueValue(value, name: name, maximumLength: 32)
        guard value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            throw BossResumeExchangeError.invalidParameter(name)
        }
    }

    private static func validateHistoryQuery(_ query: BossResumeHistoryQuery) throws {
        try validateMessageID(query.maximumMessageID, name: "maxMsgId")
        if let groupID = query.groupID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupID.isEmpty {
            try validateOpaqueValue(groupID, name: "groupId")
            guard let gid = query.gid?.trimmingCharacters(in: .whitespacesAndNewlines),
                  gid == groupID else {
                throw BossResumeExchangeError.invalidParameter("gid")
            }
            try validateOpaqueValue(gid, name: "gid")
            guard (1...100).contains(query.count), query.page >= 1 else {
                throw BossResumeExchangeError.invalidParameter("history paging")
            }
            return
        }
        try validateOpaqueValue(query.bossID, name: "bossId")
        try validateOpaqueValue(query.securityID, name: "securityId")
        guard (1...100).contains(query.count), query.page >= 1, query.source >= 0 else {
            throw BossResumeExchangeError.invalidParameter("history paging")
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        let string: String?
        if let value = value as? String {
            string = value
        } else if let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() {
            string = number.stringValue
        } else {
            string = nil
        }
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int(number.stringValue)
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int64(number.stringValue)
        }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            switch number.stringValue {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

private enum BossResumePDFValidation {
    static func isStructurallyValid(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.starts(with: Data("%PDF-".utf8)),
              let document = PDFDocument(data: data),
              document.pageCount > 0,
              !document.isLocked,
              document.page(at: 0) != nil,
              let documentReference = document.documentRef,
              documentReference.numberOfPages == document.pageCount,
              documentReference.page(at: 1) != nil else {
            return false
        }
        return true
    }
}

private enum BossResumeOfficialEndpoint: String, CaseIterable {
    case warmup = "/web/geek/chat"
    case listAttachments = "/wapi/zpgeek/resume/attachment/checkbox.json"
    case uploadPDF = "/wapi/zpupload/resume/uploadFile.json"
    case saveAttachment = "/wapi/zpgeek/resume/attachment/save.json"
    case testRequest = "/wapi/zpchat/exchange/test"
    case requestExchange = "/wapi/zpchat/exchange/request"
    case testAccept = "/wapi/zpchat/exchange/testAccept"
    case acceptExchange = "/wapi/zpchat/exchange/accept"
    case individualHistory = "/wapi/zpchat/geek/historyMsg"
    case groupHistory = "/wapi/zpchat/group/historyMsg"
    case friendSummaries = "/wapi/zprelation/friend/getGeekFriendList.json"

    var path: String { rawValue }

    var isWrite: Bool {
        switch self {
        case .uploadPDF, .saveAttachment, .requestExchange, .acceptExchange:
            true
        case .warmup, .listAttachments, .testRequest, .testAccept,
             .individualHistory, .groupHistory, .friendSummaries:
            false
        }
    }

    var responseState: BossResumeExchangeProtocolResponseState {
        switch self {
        case .warmup:
            .warmupNavigation
        case .testRequest, .testAccept:
            .statusPreflight
        case .requestExchange:
            .requestCreatedAwaitingRecruiter
        case .acceptExchange:
            .serverAcceptedUnverified
        case .listAttachments, .uploadPDF, .saveAttachment,
             .individualHistory, .groupHistory, .friendSummaries:
            .payload
        }
    }
}

private enum BossResumeRequestBody {
    case none
    case UTF8(String)
    case PDF(data: Data, fileName: String)
}

private struct BossResumeOfficialRequest {
    let endpoint: BossResumeOfficialEndpoint
    let url: URL
    let method: String
    let headers: [String: String]
    let body: BossResumeRequestBody
    let timeoutSeconds: UInt64

    private static let commonHeaders = [
        "Accept": "application/json, text/plain, */*",
        "X-Requested-With": "XMLHttpRequest",
        "with-common-headers": "true"
    ]

    static func listAttachments(from: Int) throws -> Self {
        try get(
            endpoint: .listAttachments,
            queryItems: [URLQueryItem(name: "from", value: String(from))]
        )
    }

    static func uploadPDF(data: Data, fileName: String) throws -> Self {
        Self(
            endpoint: .uploadPDF,
            url: try makeURL(endpoint: .uploadPDF),
            method: "POST",
            headers: commonHeaders,
            body: .PDF(data: data, fileName: fileName),
            timeoutSeconds: 30
        )
    }

    static func saveAttachment(previewURL: String, from: Int) throws -> Self {
        return Self(
            endpoint: .saveAttachment,
            url: try makeURL(
                endpoint: .saveAttachment,
                queryItems: [
                    URLQueryItem(name: "previewUrl", value: previewURL),
                    URLQueryItem(name: "annexType", value: "0"),
                    URLQueryItem(name: "from", value: String(from))
                ]
            ),
            method: "POST",
            headers: commonHeaders,
            body: .none,
            timeoutSeconds: 25
        )
    }

    static func testRequest(securityID: String, friendSource: Int) throws -> Self {
        try formPOST(
            endpoint: .testRequest,
            fields: [
                ("securityId", securityID),
                ("type", "3"),
                ("friendSource", String(friendSource))
            ]
        )
    }

    static func requestExchange(securityID: String, resumeToken: String) throws -> Self {
        try formPOST(
            endpoint: .requestExchange,
            fields: [
                ("securityId", securityID),
                ("type", "3"),
                ("encryptResumeId", resumeToken),
                ("mid", "")
            ]
        )
    }

    static func testAccept(securityID: String, messageID: String) throws -> Self {
        try formPOST(
            endpoint: .testAccept,
            fields: [
                ("mid", messageID),
                ("type", "4"),
                ("securityId", securityID)
            ]
        )
    }

    static func acceptExchange(
        securityID: String,
        messageID: String,
        resumeToken: String,
        scene: Int?
    ) throws -> Self {
        try formPOST(
            endpoint: .acceptExchange,
            fields: [
                ("securityId", securityID),
                ("type", "4"),
                ("mid", messageID),
                ("scene", scene.map(String.init) ?? ""),
                ("encryptResumeId", resumeToken)
            ]
        )
    }

    static func history(query: BossResumeHistoryQuery) throws -> Self {
        if let groupID = query.groupID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !groupID.isEmpty {
            let gid = query.gid?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let gid, !gid.isEmpty, gid == groupID else {
                throw BossResumeExchangeError.invalidParameter("gid")
            }
            return try get(
                endpoint: .groupHistory,
                queryItems: [
                    URLQueryItem(name: "gid", value: gid),
                    URLQueryItem(name: "maxMsgId", value: query.maximumMessageID),
                    URLQueryItem(name: "count", value: String(query.count)),
                    URLQueryItem(name: "page", value: String(query.page))
                ]
            )
        }

        var queryItems = [
            URLQueryItem(name: "bossId", value: query.bossID),
            URLQueryItem(name: "groupId", value: ""),
            URLQueryItem(name: "maxMsgId", value: query.maximumMessageID),
            URLQueryItem(name: "c", value: String(query.count)),
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "src", value: String(query.source)),
            URLQueryItem(name: "securityId", value: query.securityID)
        ]
        if let gid = query.gid {
            queryItems.append(URLQueryItem(name: "gid", value: gid))
        }
        return try get(endpoint: .individualHistory, queryItems: queryItems)
    }

    static func friendSummaries(
        friendIDs: [String],
        directFriendIDs: [String]
    ) throws -> Self {
        var seen = Set<String>()
        let normalizedFriends = friendIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        seen.removeAll()
        let normalizedDirect = directFriendIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        guard !normalizedFriends.isEmpty || !normalizedDirect.isEmpty else {
            throw BossResumeExchangeError.invalidParameter("friendIds")
        }
        var fields: [(String, String)] = []
        if !normalizedFriends.isEmpty {
            fields.append(("friendIds", normalizedFriends.joined(separator: ",")))
        }
        if !normalizedDirect.isEmpty {
            fields.append(("dzFriendIds", normalizedDirect.joined(separator: ",")))
        }
        return try formPOST(endpoint: .friendSummaries, fields: fields)
    }

    private static func get(
        endpoint: BossResumeOfficialEndpoint,
        queryItems: [URLQueryItem]
    ) throws -> Self {
        Self(
            endpoint: endpoint,
            url: try makeURL(endpoint: endpoint, queryItems: queryItems),
            method: "GET",
            headers: commonHeaders,
            body: .none,
            timeoutSeconds: 25
        )
    }

    private static func formPOST(
        endpoint: BossResumeOfficialEndpoint,
        fields: [(String, String)]
    ) throws -> Self {
        var headers = commonHeaders
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let encodedBody = try fields.map { name, value in
            guard let encodedName = formEncode(name), let encodedValue = formEncode(value) else {
                throw BossResumeExchangeError.invalidParameter(name)
            }
            return "\(encodedName)=\(encodedValue)"
        }.joined(separator: "&")
        return Self(
            endpoint: endpoint,
            url: try makeURL(endpoint: endpoint),
            method: "POST",
            headers: headers,
            body: .UTF8(encodedBody),
            timeoutSeconds: 25
        )
    }

    private static func formEncode(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    static func warmupURL() throws -> URL {
        try makeURL(endpoint: .warmup)
    }

    private static func makeURL(
        endpoint: BossResumeOfficialEndpoint,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.zhipin.com"
        components.path = endpoint.path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url, url.isAllowed(for: endpoint) else {
            throw BossResumeExchangeError.endpointNotAllowed
        }
        return url
    }
}

private extension BossResumeOfficialRequest {
    var protocolInspection: BossResumeExchangeProtocolInspection {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let contentType = headers["Content-Type"]
        let bodyDescription: (
            kind: BossResumeExchangeProtocolBodyKind,
            fields: [BossResumeExchangeProtocolField],
            text: String?
        )
        switch body {
        case .none:
            bodyDescription = (.none, [], nil)
        case .UTF8(let text):
            if contentType?.hasPrefix("application/json") == true {
                bodyDescription = (.JSON, [], text)
            } else {
                bodyDescription = (.formURLEncoded, Self.decodeFormFields(text), text)
            }
        case .PDF:
            bodyDescription = (
                .PDFMultipart,
                [
                    BossResumeExchangeProtocolField(name: "file", value: nil),
                    BossResumeExchangeProtocolField(name: "fileType", value: "1")
                ],
                nil
            )
        }

        return BossResumeExchangeProtocolInspection(
            endpointPath: endpoint.path,
            method: method,
            absoluteURL: url.absoluteString,
            queryItems: queryItems.map {
                BossResumeExchangeProtocolField(name: $0.name, value: $0.value)
            },
            bodyKind: bodyDescription.kind,
            bodyFields: bodyDescription.fields,
            bodyText: bodyDescription.text,
            contentType: contentType,
            writeMayHaveCommitted: endpoint.isWrite,
            responseState: endpoint.responseState
        )
    }

    static func decodeFormFields(_ body: String) -> [BossResumeExchangeProtocolField] {
        guard !body.isEmpty else { return [] }
        return body.split(separator: "&", omittingEmptySubsequences: false).map { component in
            let pieces = component.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let encodedName = String(pieces[0])
            let encodedValue = pieces.count == 2 ? String(pieces[1]) : nil
            return BossResumeExchangeProtocolField(
                name: encodedName.removingPercentEncoding ?? encodedName,
                value: encodedValue.map { $0.removingPercentEncoding ?? $0 }
            )
        }
    }
}

private extension URL {
    func isAllowed(for endpoint: BossResumeOfficialEndpoint) -> Bool {
        guard scheme?.lowercased() == "https",
              host?.lowercased() == "www.zhipin.com",
              user == nil,
              password == nil,
              port == nil || port == 443,
              path == endpoint.path else {
            return false
        }
        return BossResumeOfficialEndpoint.allCases.contains(endpoint)
    }

    var isAllowedWarmupURL: Bool {
        isAllowed(for: .warmup) && query == nil && fragment == nil
    }
}

@MainActor
private final class BossResumeExchangeProfileClient: NSObject, WKNavigationDelegate {
    private static let bridgeName = "bossPilotResumeExchangeBridge"
    private static let maximumBridgeBodyCharacters = 8 * 1_048_576

    private let profileID: UUID
    private let bridgeProxy: BossResumeExchangeBridgeProxy
    private var webView: WKWebView!
    private(set) var isInvalidated = false
    private var isPrepared = false
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparationID: UUID?
    private var preparationContinuation: CheckedContinuation<Void, Error>?
    private var preparationTimeout: Task<Void, Never>?
    private var requestID: UUID?
    private var requestEndpoint: BossResumeOfficialEndpoint?
    private var requestContinuation: CheckedContinuation<Data, Error>?
    private var requestTimeout: Task<Void, Never>?
    private var evaluationID: UUID?
    private var evaluationContinuation: CheckedContinuation<[String: Any], Error>?
    private var evaluationTimeout: Task<Void, Never>?

    init(profileID: UUID) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BossWebSessionService.dataStore(for: profileID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let bridgeProxy = BossResumeExchangeBridgeProxy()
        configuration.userContentController.add(bridgeProxy, name: Self.bridgeName)

        self.profileID = profileID
        self.bridgeProxy = bridgeProxy
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        bridgeProxy.target = self
        webView.customUserAgent = BossBrowserIdentity.userAgent
        webView.navigationDelegate = self
    }

    func serialized<Value: Sendable>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard !isInvalidated else { throw BossResumeExchangeError.serviceInvalidated }
        return try await operation()
    }

    func perform(
        _ request: BossResumeOfficialRequest,
        commitIsStillAuthorized: (@MainActor () -> Bool)? = nil
    ) async throws -> Data {
        guard !isInvalidated else { throw BossResumeExchangeError.serviceInvalidated }
        guard request.url.isAllowed(for: request.endpoint) else {
            throw BossResumeExchangeError.endpointNotAllowed
        }
        if !isPrepared || webView.url?.isAllowedWarmupURL != true {
            try await BossNetworkPacingGate.shared.wait(
                isWrite: false,
                discriminator: "resume-warmup|\(profileID.uuidString)",
                isStillValid: { await !self.isInvalidated }
            )
        }
        try await prepare()
        try await BossNetworkPacingGate.shared.wait(
            isWrite: request.endpoint.isWrite,
            discriminator: "resume-api|\(profileID.uuidString)|\(request.endpoint.path)",
            isStillValid: { await !self.isInvalidated }
        )
        guard !isInvalidated else { throw BossResumeExchangeError.serviceInvalidated }
        if request.endpoint.isWrite {
            guard let commitIsStillAuthorized, commitIsStillAuthorized() else {
                throw BossResumeExchangeError.authorizationChanged
            }
        }
        guard requestContinuation == nil else {
            throw BossResumeExchangeError.bridgeTransportFailed
        }

        let currentRequestID = UUID()
        let script = try makeScript(for: request, requestID: currentRequestID)
        requestID = currentRequestID
        requestEndpoint = request.endpoint
        return try await withCheckedThrowingContinuation { continuation in
            requestContinuation = continuation
            requestTimeout?.cancel()
            requestTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(request.timeoutSeconds))
                } catch {
                    return
                }
                guard let self,
                      self.requestID == currentRequestID,
                      self.requestContinuation != nil else { return }
                self.abortJavaScriptRequest(currentRequestID)
                self.finishRequest(
                    throwing: BossResumeExchangeError.requestTimedOut(
                        endpoint: request.endpoint.path,
                        writeMayHaveCommitted: request.endpoint.isWrite
                    )
                )
            }
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == currentRequestID else { return }
                    self.finishRequest(throwing: BossResumeExchangeError.bridgeEvaluationFailed)
                }
            }
        }
    }

    func pageConversationStorePayload() async throws -> [String: Any] {
        try await prepare()
        for attempt in 0..<50 {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(500))
            }
            let script = """
            (() => {
              try {
                const store = window.chatStore;
                const friendInfos = store && store.friendInfos;
                if (!friendInfos) {
                  return { ready: false, friendList: [] };
                }
                const objectValues = value => {
                  if (!value) return [];
                  if (Array.isArray(value)) return value;
                  if (value instanceof Map) return Array.from(value.values());
                  if (typeof value.values === 'function') {
                    try { return Array.from(value.values()); } catch (_) {}
                  }
                  if (typeof value.toJSON === 'function') {
                    try {
                      const json = value.toJSON();
                      if (Array.isArray(json)) return json;
                      if (json && typeof json === 'object') return Object.values(json);
                    } catch (_) {}
                  }
                  return typeof value === 'object' ? Object.values(value) : [];
                };
                const text = value => value == null ? '' : String(value).trim();
                const number = value => {
                  const parsed = Number(value);
                  return Number.isFinite(parsed) ? parsed : 0;
                };
                const first = (...values) => {
                  for (const value of values) {
                    const normalized = text(value);
                    if (normalized) return normalized;
                  }
                  return '';
                };
                // `friendInfos` is a long-lived cache and may contain hundreds
                // of expired placeholders without securityId. The official
                // `localFriends` index is the authoritative set currently
                // addressable by the message page. Never fall back to every
                // cached object: doing so creates rows which cannot be routed
                // to historyMsg.
                const friendKeys = objectValues(store.localFriends || store.friends)
                  .map(value => typeof value === 'object'
                    ? first(value.uniqueId, value.id, value.friendId)
                    : text(value))
                  .filter(Boolean);
                const values = friendKeys.map(key => {
                  if (typeof store.getFriendsInfoById === 'function') {
                    try {
                      const friend = store.getFriendsInfoById(key);
                      if (friend) return friend;
                    } catch (_) {}
                  }
                  return friendInfos[key];
                }).filter(Boolean);
                const normalized = values.map(friend => {
                  const last = friend && typeof friend.lastMsg === 'object'
                    ? friend.lastMsg
                    : (friend && typeof friend.lastMessage === 'object' ? friend.lastMessage : {});
                  const body = last && typeof last.body === 'object' ? last.body : {};
                  const action = body && typeof body.action === 'object' ? body.action : {};
                  const from = last && typeof last.from === 'object' ? last.from : {};
                  const to = last && typeof last.to === 'object' ? last.to : {};
                  const uniqueID = first(friend && friend.uniqueId);
                  const uniqueIDSeparator = uniqueID.lastIndexOf('-');
                  const friendID = first(
                    friend && friend.friendId,
                    friend && friend.uid,
                    friend && friend.bossId,
                    uniqueIDSeparator > 0 ? uniqueID.slice(0, uniqueIDSeparator) : ''
                  );
                  const source = first(
                    friend && friend.friendSource,
                    friend && friend.bossSource,
                    friend && friend.source,
                    uniqueIDSeparator > 0 ? uniqueID.slice(uniqueIDSeparator + 1) : ''
                  );
                  const lastText = typeof (friend && friend.lastMsg) === 'string'
                    ? text(friend.lastMsg)
                    : first(
                        body.text, body.content, body.message,
                        last.text, last.content,
                        friend && friend.lastText,
                        friend && friend.lastMessage
                      );
                  return {
                    friendId: friendID,
                    friendSource: source,
                    name: first(friend && friend.name, friend && friend.bossName, friend && friend.recruiterName),
                    brandName: first(friend && friend.brandName, friend && friend.companyName, friend && friend.company),
                    jobName: first(friend && friend.jobName, friend && friend.positionName, friend && friend.jobTitle),
                    lastText,
                    unreadCount: number(friend && (friend.unreadCount ?? friend.num)),
                    updateTime: number(
                      (last && (last.time ?? last.timestamp)) ??
                      (friend && (friend.updateTime ?? friend.lastTS ?? friend.time))
                    ),
                    securityId: first(friend && friend.securityId, friend && friend.securityID),
                    lid: first(friend && friend.lid, friend && friend.listId),
                    encryptBossId: first(
                      friend && friend.encryptBossId,
                      friend && friend.encryptUserId,
                      friend && friend.encryptUid,
                      friendID
                    ),
                    gid: first(friend && friend.gid, friend && friend.groupId),
                    lastMsg: {
                      mid: first(last.mid, last.messageId, friend && friend.lastMsgId),
                      fromId: first(last.fromId, last.senderId, from.uid, from.id),
                      toId: first(last.toId, last.recipientId, to.uid, to.id),
                      type: number(last.type ?? last.messageType ?? body.type),
                      aid: number(last.aid ?? last.actionId ?? action.aid),
                      scene: number(last.scene ?? body.scene)
                    }
                  };
                }).filter(friend => friend.friendId);
                // `window.chatStore.friendInfos` is allocated as an empty
                // object before the official page has hydrated its chat
                // worker. Treating that shell as ready manufactured a false
                // successful sync with zero conversations. Only publish after
                // at least one stable conversation has materialized; a true
                // empty/unavailable store fails closed after the bounded wait.
                return {
                  ready: normalized.length > 0,
                  friendList: normalized
                };
              } catch (_) {
                return { ready: false, friendList: [] };
              }
            })()
            """
            let result = try await evaluateDictionary(script)
            if result["ready"] as? Bool == true {
                return result
            }
        }
        throw BossResumeExchangeError.conversationStoreUnavailable
    }

    /// 从发起历史请求的同一官方页面读取聊天身份命名空间。
    func authenticatedCurrentUserID() async throws -> String? {
        try await prepare()
        let result = try await evaluateDictionary(
            """
            (() => ({
              currentUserID: String(
                (window._PAGE && (window._PAGE.uid || window._PAGE.userId)) || ''
              ).trim()
            }))()
            """
        )
        return Self.nonempty(result["currentUserID"])
    }

    func waitForGreetingConversation(
        expectedSecurityID: String,
        expectedJobID: String
    ) async throws -> BossGreetingConversationContext {
        // 优先复用已加载路由，仅在 friend/add 尚未写入页面缓存时重新加载。
        try await prepare()
        var lastFriendCount = 0
        var lastTargetLocated = false
        var lastConnected = false
        var lastSelectedHasFriend = false
        for attempt in 0..<50 {
            try Task.checkCancellation()
            if attempt == 1 {
                isPrepared = false
                try await prepare()
            }
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(500))
            }
            let script = """
            (() => {
              try {
              const expectedSecurityID = \(try Self.JSONString(expectedSecurityID));
              const expectedJobID = \(try Self.JSONString(expectedJobID));
              const captureWebpackRequire = () => {
                if (!Array.isArray(window.webpackChunkGeekChat)) {
                  return undefined;
                }
                let webpackRequire;
                const chunkID = Math.floor(Date.now() % 1000000000) + 1000000000;
                window.webpackChunkGeekChat.push([
                  [chunkID],
                  {},
                  require => { webpackRequire = require; }
                ]);
                return webpackRequire;
              };
              const friendInfos = window.chatStore && window.chatStore.friendInfos;
              const friends = friendInfos ? Object.values(friendInfos) : [];
              const remoteJobID = friend => String(
                (friend && (friend.encryptJobId || friend.encryptJobID || friend.jobId)) || ''
              );
              const target = friends.find(friend => remoteJobID(friend) === expectedJobID);
              const selected = window.chat && window.chat.communicating;
              const connected = Boolean(
                window.ChatWebsocket &&
                window.ChatWebsocket.client &&
                typeof window.ChatWebsocket.client.isConnected === 'function' &&
                window.ChatWebsocket.client.isConnected()
              );
              if (!target || !target.friendId) {
                return {
                  ready: false,
                  connected,
                  targetLocated: Boolean(target),
                  friendCount: friends.length,
                  selectedHasFriend: Boolean(selected && selected.friendId)
                };
              }
              const webpackRequire = captureWebpackRequire();
              const selectionModule = webpackRequire && webpackRequire(42769);
              const selectedFriend = selectionModule && selectionModule.A &&
                selectionModule.A.subject && selectionModule.A.subject.selectedFriend$;
              if (!selectedFriend || typeof selectedFriend.next !== 'function') {
                return {
                  ready: false,
                  connected,
                  targetLocated: true,
                  friendCount: friends.length,
                  selectedHasFriend: false,
                  scriptError: 'selectedFriend subject unavailable'
                };
              }
              const currentSelection = selectedFriend.value || {};
              const currentSelectionID = String(currentSelection.uniqueId || '');
              const targetSelectionID = String(target.uniqueId || '');
              if (!targetSelectionID) {
                return {
                  ready: false,
                  connected,
                  targetLocated: true,
                  friendCount: friends.length,
                  selectedHasFriend: false,
                  scriptError: 'target uniqueId unavailable'
                };
              }
              if (currentSelectionID !== targetSelectionID) {
                selectedFriend.next(target);
              }
              const selectedAfterUpdate = selectedFriend.value || {};
              const selectionMatches = remoteJobID(selectedAfterUpdate) === expectedJobID;
              // The official controller reads its route from selectedFriend$.
              // getBossInfo may leave conversationLoading$ true when an old
              // contact card can no longer be enriched, even though the exact
              // route and the chat WebSocket are both usable.
              const controllerReady = Boolean(selectionMatches);
              if (!controllerReady) {
                return {
                  ready: false,
                  connected,
                  targetLocated: true,
                  friendCount: friends.length,
                  selectedHasFriend: selectionMatches,
                  controllerLoading: Boolean(
                    window.chat && window.chat.conversationLoading$ &&
                    window.chat.conversationLoading$.value
                  )
                };
              }
              const route = selectedAfterUpdate;
              return {
                ready: true,
                connected,
                targetLocated: Boolean(target),
                friendCount: friends.length,
                selectedHasFriend: true,
                recruiterName: String(route.name || route.bossName || target.name || target.bossName || ''),
                friendID: String(route.friendId || route.uid || ''),
                encryptedBossID: String(route.encryptBossId || route.encryptUid || ''),
                remoteJobID: remoteJobID(route),
                securityID: String(route.securityId || ''),
                friendSource: Number(route.friendSource || route.bossSource || 0),
                currentUserID: String((window._PAGE && (window._PAGE.uid || window._PAGE.userId)) || '')
              };
              } catch (error) {
                return {
                  ready: false,
                  scriptError: String((error && (error.stack || error.message || error.name)) || 'unknown')
                };
              }
            })();
            """
            let result = try await evaluateDictionary(script)
            if let scriptError = result["scriptError"] as? String {
                fputs("BOSS GREETING TARGET ERROR: \(scriptError.prefix(500))\n", stderr)
                throw BossResumeExchangeError.bridgeEvaluationFailed
            }
            lastFriendCount = (result["friendCount"] as? NSNumber)?.intValue ?? 0
            lastTargetLocated = result["targetLocated"] as? Bool ?? false
            lastConnected = result["connected"] as? Bool ?? false
            lastSelectedHasFriend = result["selectedHasFriend"] as? Bool ?? false
            guard result["ready"] as? Bool == true else { continue }
            guard result["connected"] as? Bool == true else {
                if attempt == 49 {
                    throw BossResumeExchangeError.greetingWebSocketUnavailable
                }
                continue
            }
            guard let recruiterName = Self.nonempty(result["recruiterName"]),
                  let friendID = Self.nonempty(result["friendID"]),
                  let encryptedBossID = Self.nonempty(result["encryptedBossID"]),
                  let remoteJobID = Self.nonempty(result["remoteJobID"]),
                  let securityID = Self.nonempty(result["securityID"]),
                  let currentUserID = Self.nonempty(result["currentUserID"]),
                  let friendSource = (result["friendSource"] as? NSNumber)?.intValue,
                  friendSource >= 0 else {
                throw BossResumeExchangeError.greetingConversationUnavailable
            }
            guard remoteJobID == expectedJobID else {
                throw BossResumeExchangeError.greetingConversationMismatch
            }
            return BossGreetingConversationContext(
                recruiterName: recruiterName,
                friendID: friendID,
                encryptedBossID: encryptedBossID,
                remoteJobID: remoteJobID,
                securityID: securityID,
                friendSource: friendSource,
                currentUserID: currentUserID
            )
        }
        fputs(
            "BOSS GREETING TARGET STATE: friends=\(lastFriendCount) target=\(lastTargetLocated) selected=\(lastSelectedHasFriend) websocket=\(lastConnected)\n",
            stderr
        )
        throw BossResumeExchangeError.greetingConversationUnavailable
    }

    func sendGreeting(
        context: BossGreetingConversationContext,
        text: String
    ) async throws {
        let specification: [String: Any] = [
            "text": text,
            "friendID": context.friendID,
            "encryptedBossID": context.encryptedBossID,
            "remoteJobID": context.remoteJobID,
            "friendSource": context.friendSource,
            "securityID": context.securityID
        ]
        guard JSONSerialization.isValidJSONObject(specification),
              let data = try? JSONSerialization.data(withJSONObject: specification),
              let JSON = String(data: data, encoding: .utf8) else {
            throw BossResumeExchangeError.bridgeEvaluationFailed
        }
        let script = """
          const specification = \(JSON);
          const captureWebpackRequire = () => {
            if (!Array.isArray(window.webpackChunkGeekChat)) return undefined;
            let webpackRequire;
            const chunkID = Math.floor(Date.now() % 1000000000) + 1000000000;
            window.webpackChunkGeekChat.push([
              [chunkID],
              {},
              require => { webpackRequire = require; }
            ]);
            return webpackRequire;
          };
          const webpackRequire = captureWebpackRequire();
          const selectionModule = webpackRequire && webpackRequire(42769);
          const messageSenderModule = webpackRequire && webpackRequire(33614);
          const messageSender = messageSenderModule && messageSenderModule.A;
          const selectedFriend = selectionModule && selectionModule.A &&
            selectionModule.A.subject && selectionModule.A.subject.selectedFriend$;
          const active = (selectedFriend && selectedFriend.value) || {};
          if (!active ||
              String(active.encryptJobId || active.encryptJobID || active.jobId || '') !== specification.remoteJobID ||
              String(active.securityId || '') !== specification.securityID ||
              String(active.friendId || active.uid || '') !== specification.friendID ||
              String(active.encryptBossId || active.encryptUid || '') !== specification.encryptedBossID) {
            return { sent: false, reason: 'conversationMismatch' };
          }
          if (!window.ChatWebsocket || !window.ChatWebsocket.client ||
              typeof window.ChatWebsocket.client.isConnected !== 'function' ||
              !window.ChatWebsocket.client.isConnected()) {
            return { sent: false, reason: 'webSocketUnavailable' };
          }
          if (!messageSender || typeof messageSender.sendMessage !== 'function') {
            return { sent: false, reason: 'senderUnavailable' };
          }
          return await new Promise(resolve => {
            let settled = false;
            let syncSubscription;
            let messageSubscription;
            let expectedClientMessageID;
            const positiveInteger = value => {
              if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) {
                return value;
              }
              if (typeof value === 'string' && /^\\d+$/.test(value)) {
                const parsed = Number(value);
                return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
              }
              if (value && typeof value.toString === 'function') {
                const text = String(value.toString());
                if (/^\\d+$/.test(text)) {
                  const parsed = Number(text);
                  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
                }
              }
              return undefined;
            };
            const finish = result => {
              if (settled) return;
              settled = true;
              if (syncSubscription && typeof syncSubscription.unsubscribe === 'function') {
                syncSubscription.unsubscribe();
              }
              if (messageSubscription && typeof messageSubscription.unsubscribe === 'function') {
                messageSubscription.unsubscribe();
              }
              resolve(result);
            };
            const syncStream = window.ChatWebsocket && window.ChatWebsocket.sync$;
            const messageStream = window.ChatWebsocket && window.ChatWebsocket.message$;
            if (!syncStream || typeof syncStream.subscribe !== 'function' ||
                !messageStream || typeof messageStream.subscribe !== 'function') {
              finish({ sent: false, reason: 'syncUnavailable' });
              return;
            }
            messageSubscription = messageStream.subscribe(messageItems => {
              const items = Array.isArray(messageItems) ? messageItems : [];
              const localMessage = items.find(item =>
                item && item.isSelf === true && item.body &&
                String(item.body.text || '').trim() === specification.text.trim() &&
                String(item.to && item.to.uid || '') === specification.friendID
              );
              if (!localMessage) return;
              expectedClientMessageID = positiveInteger(
                localMessage.mid || localMessage.cmid || localMessage.tempID
              );
            });
            syncSubscription = syncStream.subscribe(syncItems => {
              const items = Array.isArray(syncItems) ? syncItems : [];
              const receipt = items.find(item => {
                const clientMID = positiveInteger(item && item.clientMid);
                const serverMID = positiveInteger(item && item.serverMid);
                return expectedClientMessageID && clientMID === expectedClientMessageID && serverMID;
              });
              if (receipt) {
                finish({
                  sent: true,
                  clientMessageID: String(receipt.clientMid),
                  serverMessageID: String(receipt.serverMid)
                });
              }
            });
            try {
              messageSender.sendMessage(
                {
                  uid: specification.friendID,
                  friendSource: specification.friendSource,
                  encryptUid: specification.encryptedBossID
                },
                specification.text,
                'text'
              );
            } catch (error) {
              finish({
                sent: false,
                reason: 'sendException',
                errorName: String((error && error.name) || '')
              });
              return;
            }
            setTimeout(() => finish({ sent: false, reason: 'acknowledgementTimeout' }), 15000);
          });
        """
        let result = try await evaluateAsyncDictionary(script)
        guard result["sent"] as? Bool == true else {
            switch result["reason"] as? String {
            case "conversationMismatch":
                throw BossResumeExchangeError.greetingConversationMismatch
            case "webSocketUnavailable", "senderUnavailable", "syncUnavailable":
                throw BossResumeExchangeError.greetingWebSocketUnavailable
            default:
                throw BossResumeExchangeError.bridgeEvaluationFailed
            }
        }
    }

    /// 使用异步 JavaScript 桥等待 sendMessage 的 Promise，避免已提交消息因结果无法桥接而被误判失败。
    private func evaluateAsyncDictionary(_ script: String) async throws -> [String: Any] {
        try await evaluateDictionary(script, asynchronous: true)
    }

    private func evaluateDictionary(_ script: String, asynchronous: Bool = false) async throws -> [String: Any] {
        guard !isInvalidated, let webView else { throw BossResumeExchangeError.serviceInvalidated }
        try Task.checkCancellation()
        guard evaluationContinuation == nil else { throw BossResumeExchangeError.bridgeEvaluationFailed }
        let currentID = UUID()
        evaluationID = currentID
        return try await withCheckedThrowingContinuation { continuation in
            evaluationContinuation = continuation
            evaluationTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.evaluationID == currentID else { return }
                self.isPrepared = false
                self.finishEvaluation(.failure(BossResumeExchangeError.bridgeEvaluationFailed))
            }
            let complete: (Any?, Error?) -> Void = { [weak self] value, error in
                MainActor.assumeIsolated {
                    guard let self, self.evaluationID == currentID else { return }
                    if let error {
                        let description = String(error.localizedDescription.prefix(500))
                        fputs("BOSS GREETING JAVASCRIPT ERROR: \(description)\n", stderr)
                        self.finishEvaluation(.failure(BossResumeExchangeError.bridgeEvaluationFailed))
                    } else if let dictionary = value as? [String: Any] {
                        self.finishEvaluation(.success(dictionary))
                    } else {
                        self.finishEvaluation(.failure(BossResumeExchangeError.bridgeEvaluationFailed))
                    }
                }
            }
            if asynchronous {
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): complete(value, nil)
                    case .failure(let error): complete(nil, error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script, completionHandler: complete)
            }
        }
    }

    private func finishEvaluation(_ result: Result<[String: Any], Error>) {
        evaluationTimeout?.cancel()
        evaluationTimeout = nil
        evaluationID = nil
        let continuation = evaluationContinuation
        evaluationContinuation = nil
        continuation?.resume(with: result)
    }

    static func verifyJavaScriptLifecycle() async throws {
        let profileID = UUID()
        BossWebSessionService.beginRetiring(profileID: profileID)
        let client = BossResumeExchangeProfileClient(profileID: profileID)
        defer { client.invalidate() }
        client.webView.navigationDelegate = nil
        client.webView.loadHTMLString(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'\">",
            baseURL: nil
        )
        let readyDeadline = Date().addingTimeInterval(5)
        while client.webView.isLoading, Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let value = try await client.evaluateDictionary("({value: 1})")
        guard value["value"] as? Int == 1 else { throw SelfCheckError.failed("同步 JavaScript 桥接失败") }
        let startedAt = Date()
        do {
            _ = try await client.evaluateAsyncDictionary(
                "window.fixturePending = new Promise(resolve => window.fixtureTimeoutResolve = resolve); return await window.fixturePending;"
            )
            throw SelfCheckError.failed("不返回的 JavaScript 未超时")
        } catch BossResumeExchangeError.bridgeEvaluationFailed {}
        let timeoutDuration = Date().timeIntervalSince(startedAt)
        guard timeoutDuration >= 14, timeoutDuration < 20 else {
            throw SelfCheckError.failed("JavaScript 超时未释放账号任务")
        }
        let recovered = try await client.evaluateAsyncDictionary("return {value: 2};")
        guard recovered["value"] as? Int == 2 else { throw SelfCheckError.failed("超时后无法执行新 JavaScript") }
        let terminated = Task {
            try await client.evaluateAsyncDictionary("return await new Promise(resolve => window.fixtureResolve = resolve);")
        }
        try await Task.sleep(for: .milliseconds(100))
        client.webViewWebContentProcessDidTerminate(client.webView)
        do {
            _ = try await terminated.value
            throw SelfCheckError.failed("页面进程退出未释放等待器")
        } catch BossResumeExchangeError.bridgeEvaluationFailed {}
        let replacement = Task {
            try await client.evaluateAsyncDictionary("return await new Promise(resolve => setTimeout(() => resolve({value: 3}), 200));")
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await client.webView.evaluateJavaScript("window.fixtureResolve({value: 99}); null")
        let replacementValue = try await replacement.value
        guard replacementValue["value"] as? Int == 3 else {
            throw SelfCheckError.failed("迟到 JavaScript 回调污染了新任务")
        }
        let invalidated = Task { try await client.evaluateAsyncDictionary("return await new Promise(() => {});") }
        try await Task.sleep(for: .milliseconds(100))
        client.invalidate()
        do {
            _ = try await invalidated.value
            throw SelfCheckError.failed("服务失效未释放 JavaScript 等待器")
        } catch BossResumeExchangeError.serviceInvalidated {}
        print(String(format: "WEBKIT resume JavaScript: timeout %.2f s; recovery, late callback and invalidation passed", timeoutDuration))
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        isPrepared = false
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        preparationTimeout?.cancel()
        preparationTimeout = nil
        let pendingPreparation = preparationContinuation
        preparationContinuation = nil
        preparationID = nil
        pendingPreparation?.resume(throwing: BossResumeExchangeError.serviceInvalidated)
        if let currentRequestID = requestID {
            abortJavaScriptRequest(currentRequestID)
        }
        finishRequest(throwing: BossResumeExchangeError.serviceInvalidated)
        finishEvaluation(.failure(BossResumeExchangeError.serviceInvalidated))
        let waiters = operationWaiters
        operationWaiters.removeAll()
        operationInFlight = false
        waiters.forEach { $0.resume() }
        webView.navigationDelegate = nil
        webView = nil
    }

    private func acquireOperation() async {
        if !operationInFlight {
            operationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationInFlight = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func prepare() async throws {
        guard !isInvalidated else { throw BossResumeExchangeError.serviceInvalidated }
        guard await BossWebSessionService.isAuthenticated(profileID: profileID) else {
            throw BossResumeExchangeError.unauthenticated
        }
        guard !isInvalidated else { throw BossResumeExchangeError.serviceInvalidated }
        if isPrepared, webView.url?.isAllowedWarmupURL == true { return }
        guard preparationContinuation == nil else {
            throw BossResumeExchangeError.navigationFailed
        }

        let currentPreparationID = UUID()
        preparationID = currentPreparationID
        isPrepared = false
        let warmupURL = try BossResumeOfficialRequest.warmupURL()
        try await withCheckedThrowingContinuation { continuation in
            preparationContinuation = continuation
            preparationTimeout?.cancel()
            preparationTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(25))
                } catch {
                    return
                }
                guard let self,
                      self.preparationID == currentPreparationID,
                      self.preparationContinuation != nil else { return }
                self.webView.stopLoading()
                self.finishPreparation(throwing: BossResumeExchangeError.navigationTimedOut)
            }
            var request = URLRequest(
                url: warmupURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 25
            )
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            webView.load(request)
        }
    }

    private func makeScript(
        for request: BossResumeOfficialRequest,
        requestID: UUID
    ) throws -> String {
        var specification: [String: Any] = [
            "requestID": requestID.uuidString,
            "URL": request.url.absoluteString,
            "method": request.method,
            "headers": request.headers,
            "timeoutMilliseconds": Int(request.timeoutSeconds * 1_000) - 500,
            "maximumBodyCharacters": Self.maximumBridgeBodyCharacters
        ]
        switch request.body {
        case .none:
            specification["bodyKind"] = "none"
        case .UTF8(let body):
            specification["bodyKind"] = "text"
            specification["body"] = body
        case .PDF(let data, let fileName):
            specification["bodyKind"] = "pdf"
            specification["base64"] = data.base64EncodedString()
            specification["fileName"] = fileName
        }
        guard JSONSerialization.isValidJSONObject(specification),
              let JSONData = try? JSONSerialization.data(withJSONObject: specification),
              let JSON = String(data: JSONData, encoding: .utf8) else {
            throw BossResumeExchangeError.bridgeEvaluationFailed
        }

        return """
        void (async () => {
          const specification = \(JSON);
          const registryName = '__bossPilotResumeExchangeControllers';
          window[registryName] = window[registryName] || Object.create(null);
          const controller = new AbortController();
          window[registryName][specification.requestID] = controller;
          const timeout = window.setTimeout(
            () => controller.abort(),
            specification.timeoutMilliseconds
          );
          const post = value => window.webkit.messageHandlers[\(try Self.JSONString(Self.bridgeName))]
            .postMessage(JSON.stringify(value));
          try {
            let body;
            const headers = Object.assign({}, specification.headers);
            const URL = new window.URL(specification.URL, window.location.origin);
            if (URL.origin !== window.location.origin || !URL.hostname.endsWith('zhipin.com')) {
              throw new Error('cross-origin request rejected');
            }
            URL.searchParams.set('_', String(Date.now()));
            headers.traceId = (window.crypto && typeof window.crypto.randomUUID === 'function')
              ? window.crypto.randomUUID().replaceAll('-', '')
              : String(Date.now()) + Math.random().toString(16).slice(2);
            const pageToken = window._PAGE && window._PAGE.token
              ? String(window._PAGE.token).split('|')[0]
              : '';
            if (pageToken) headers.token = pageToken;
            const bstMatch = document.cookie.match(/(?:^|;\\s*)bst=([^;]+)/);
            if (bstMatch && bstMatch[1]) headers.zp_token = decodeURIComponent(bstMatch[1]);
            if (specification.bodyKind === 'pdf') {
              const binary = window.atob(specification.base64);
              const bytes = new Uint8Array(binary.length);
              for (let index = 0; index < binary.length; index += 1) {
                bytes[index] = binary.charCodeAt(index);
              }
              const form = new FormData();
              form.append(
                'file',
                new Blob([bytes], { type: 'application/pdf' }),
                specification.fileName
              );
              form.append('fileType', '1');
              body = form;
            } else if (specification.bodyKind === 'text') {
              body = specification.body;
            }
            const response = await fetch(URL.toString(), {
              method: specification.method,
              credentials: 'include',
              cache: 'no-store',
              redirect: 'error',
              headers,
              body,
              signal: controller.signal
            });
            const responseBody = await response.text();
            if (responseBody.length > specification.maximumBodyCharacters) {
              post({ requestID: specification.requestID, errorKind: 'responseTooLarge' });
            } else {
              post({
                requestID: specification.requestID,
                status: response.status,
                body: responseBody
              });
            }
          } catch (_) {
            post({ requestID: specification.requestID, errorKind: 'transport' });
          } finally {
            window.clearTimeout(timeout);
            delete window[registryName][specification.requestID];
          }
        })();
        null;
        """
    }

    private static func JSONString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let array = String(data: data, encoding: .utf8),
              array.count >= 2 else {
            throw BossResumeExchangeError.bridgeEvaluationFailed
        }
        return String(array.dropFirst().dropLast())
    }

    private func abortJavaScriptRequest(_ requestID: UUID) {
        let ID = requestID.uuidString
        guard let literal = try? Self.JSONString(ID) else { return }
        let script = "window.__bossPilotResumeExchangeControllers?.[\(literal)]?.abort(); null;"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func receiveBridgePayload(_ text: String?) {
        guard let text,
              text.utf8.count <= Self.maximumBridgeBodyCharacters + 4_096,
              let data = text.data(using: .utf8),
              let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let incomingID = wrapper["requestID"] as? String,
              incomingID == requestID?.uuidString,
              let endpoint = requestEndpoint else {
            return
        }
        if let errorKind = wrapper["errorKind"] as? String {
            let error: BossResumeExchangeError = errorKind == "responseTooLarge"
                ? .responseTooLarge
                : .bridgeTransportFailed
            finishRequest(throwing: error)
            return
        }
        guard let status = (wrapper["status"] as? NSNumber)?.intValue,
              let body = wrapper["body"] as? String,
              let bodyData = body.data(using: .utf8) else {
            finishRequest(
                throwing: BossResumeExchangeError.invalidResponse(endpoint: endpoint.path)
            )
            return
        }
        guard (200...299).contains(status) else {
            finishRequest(
                throwing: BossResumeExchangeError.httpStatus(
                    endpoint: endpoint.path,
                    status: status,
                    writeMayHaveCommitted: endpoint.isWrite
                )
            )
            return
        }
        finishRequest(returning: bodyData)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            guard isMainFrame else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.request.url?.isAllowedWarmupURL == true {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if preparationContinuation != nil {
                    finishPreparation(throwing: BossResumeExchangeError.endpointNotAllowed)
                }
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard navigationResponse.isForMainFrame else {
                decisionHandler(.cancel)
                return
            }
            if navigationResponse.response.url?.isAllowedWarmupURL == true {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if preparationContinuation != nil {
                    finishPreparation(throwing: BossResumeExchangeError.endpointNotAllowed)
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard webView.url?.isAllowedWarmupURL == true else {
                finishPreparation(throwing: BossResumeExchangeError.endpointNotAllowed)
                return
            }
            isPrepared = true
            finishPreparation()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            finishPreparation(throwing: BossResumeExchangeError.navigationFailed)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            finishPreparation(throwing: BossResumeExchangeError.navigationFailed)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            isPrepared = false
            finishPreparation(throwing: BossResumeExchangeError.navigationFailed)
            let error = BossResumeExchangeError.requestTimedOut(
                endpoint: requestEndpoint?.path ?? "WebKit",
                writeMayHaveCommitted: requestEndpoint?.isWrite ?? false
            )
            finishRequest(throwing: error)
            finishEvaluation(.failure(BossResumeExchangeError.bridgeEvaluationFailed))
        }
    }

    private func finishPreparation(throwing error: Error? = nil) {
        preparationTimeout?.cancel()
        preparationTimeout = nil
        preparationID = nil
        let continuation = preparationContinuation
        preparationContinuation = nil
        if let error {
            isPrepared = false
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private func finishRequest(returning data: Data) {
        requestTimeout?.cancel()
        requestTimeout = nil
        requestID = nil
        requestEndpoint = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(returning: data)
    }

    private func finishRequest(throwing error: Error) {
        requestTimeout?.cancel()
        requestTimeout = nil
        requestID = nil
        requestEndpoint = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(throwing: error)
    }
}

@MainActor
private final class BossResumeExchangeBridgeProxy: NSObject, WKScriptMessageHandler {
    weak var target: BossResumeExchangeProfileClient?

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard message.name == "bossPilotResumeExchangeBridge" else { return }
            target?.receiveBridgePayload(message.body as? String)
        }
    }
}
