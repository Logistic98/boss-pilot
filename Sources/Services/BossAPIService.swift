import Foundation
import CoreFoundation

struct BossRemoteJob: Hashable, Sendable {
    var remoteJobID: String
    var securityID: String
    var listID: String
    var title: String
    var company: String
    var location: String
    var salary: String
    var experience: String
    var education: String
    var description: String
    var recruiterName: String
    var url: String
    var recruiterTitle: String = ""
    var industry: String = ""
    var companySize: String = ""
    var financingStage: String = ""
    var tags: [String] = []
    var benefits: [String] = []

    var stableRemoteKey: String {
        if !remoteJobID.isEmpty { return "remote:\(remoteJobID)" }
        if let path = URL(string: url)?.path.nilIfBlank,
           path.contains("/job_detail/"),
           let slug = path.split(separator: "/").last,
           slug != "job_detail",
           slug.hasSuffix(".html") {
            return "path:\(path)"
        }
        let evidence = [title, company, location, experience, education]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
        if evidence.replacingOccurrences(of: "|", with: "").isEmpty {
            return "security:\(securityID)"
        }
        return "evidence:\(evidence)"
    }

    func listing(accountID: UUID, detailFetchedAt: Date? = nil) -> JobListing {
        let stableSource = [accountID.uuidString, stableRemoteKey].joined(separator: "|")
        var listing = JobListing(
            id: "boss-\(StableIdentifier.fnv1a64(stableSource))",
            accountID: accountID,
            title: title,
            company: company,
            location: BossCityResolver.displayText(for: location),
            salary: salary,
            experience: experience,
            education: education,
            description: description,
            url: url
        )
        listing.securityID = securityID.nilIfBlank
        listing.listID = listID.nilIfBlank
        listing.remoteJobID = remoteJobID.nilIfBlank
        listing.recruiterName = recruiterName.nilIfBlank
        listing.recruiterTitle = recruiterTitle.nilIfBlank
        listing.industry = BossIndustryResolver.displayText(for: industry).nilIfBlank
        listing.companySize = companySize.nilIfBlank
        listing.financingStage = financingStage.nilIfBlank
        listing.tags = tags.isEmpty ? nil : tags
        listing.benefits = benefits.isEmpty ? nil : benefits
        listing.detailFetchedAt = detailFetchedAt
        return listing
    }
}

struct BossFriendSummary: Hashable, Sendable {
    var conversationID: String
    var recruiterName: String
    var company: String
    var jobTitle: String
    var latestText: String
    var unreadCount: Int
    var updatedAt: Date
    var securityID: String
    var listID: String
    var latestIsIncoming: Bool?
    var encryptedBossID: String = ""
    var friendSource: String = ""
    var groupID: String = ""
    var latestRemoteMID: String = ""
    var latestSenderID: String = ""
    var latestRecipientID: String = ""
    var latestMessageType: Int? = nil
    var latestActionAID: Int? = nil
    var latestScene: Int? = nil
    var latestDirectionIsAuthoritative: Bool = false
    var jobSalary: String = ""
    var jobLocation: String = ""
}

struct BossAPIResult<Value: Sendable>: Sendable {
    var value: Value
    var refreshedCredential: BossCredential
    var warnings: [String] = []
}

enum BossAPIOperation: String, Sendable {
    case searchJobs = "岗位检索"
    case jobDetail = "岗位详情"
    case friendSummaries = "沟通列表"
    case dailyCommunications = "每日沟通统计"
    case dailyResumeExchanges = "每日交换统计"
    case accountUserInfo = "账号基本资料"
    case accountResumeBase = "在线简历资料"
    case accountExpectations = "求职期望"
    case accountEducation = "教育经历"
    case accountWorkHistory = "工作经历"
    case accountSelfDescription = "个人优势"
    case greet = "打招呼"
}

enum BossServerFailurePolicy {
    static let manualVerificationCodes: Set<Int> = [32, 35, 36, 121, 122]

    static func requiresManualVerification(_ code: Int) -> Bool {
        manualVerificationCodes.contains(code)
    }

    static func requiresSafetyCooldown(_ error: BossAPIError) -> Bool {
        switch error {
        case .httpStatus(429), .httpStatus(403), .manualVerificationRequired:
            return true
        case .upstream(_, let code, let message):
            let riskMarkers = [
                "频繁", "限流", "too many requests", "rate limit",
                "账号已封禁", "账号被封禁", "账号已冻结", "账号被冻结",
                "account suspended", "account banned"
            ]
            return code == 9 || riskMarkers.contains {
                message.localizedCaseInsensitiveContains($0)
            }
        default:
            return false
        }
    }

    static func error(
        operation: BossAPIOperation,
        code: Int,
        message: String?
    ) -> BossAPIError {
        switch code {
        case 7:
            return .authenticationRequired
        case 37, 1011:
            return .webTokenExpired
        case let code where requiresManualVerification(code):
            return .manualVerificationRequired(
                operation: operation,
                code: code,
                message: message?.nilIfBlank ?? "BOSS 要求本人完成安全验证"
            )
        default:
            return .upstream(
                operation: operation,
                code: code,
                message: message?.nilIfBlank ?? "未知错误"
            )
        }
    }
}

struct BossManualVerificationPageEvidence: Equatable, Sendable {
    let code: Int
}

/// 仅识别官方验证 URL 及已知错误码，普通页面跳转不能触发账号停用。
enum BossManualVerificationPagePolicy {
    static func evidence(from url: URL?) -> BossManualVerificationPageEvidence? {
        guard let url,
              OfficialBossLinkService.isOfficialURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let path = url.path.lowercased()
        guard path.contains("/verify") || path.contains("security-check") else { return nil }
        guard let rawCode = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let code = Int(rawCode),
              BossServerFailurePolicy.requiresManualVerification(code) else {
            return nil
        }
        return BossManualVerificationPageEvidence(code: code)
    }
}

struct BossSearchRequestDescriptor: Equatable, Sendable {
    static let path = "/wapi/zpgeek/search/joblist.json"
    let method: BossWebAPIRequest.Method = .POST
    let queryItems: [URLQueryItem] = []
    let formItems: [URLQueryItem]
    let referer: String

    init(query: String, cityCode: String, page: Int) {
        let normalizedQuery = BossSearchRequestPolicy.normalizedQuery(query)
        formItems = [
            URLQueryItem(name: "query", value: normalizedQuery),
            URLQueryItem(name: "city", value: cityCode),
            URLQueryItem(name: "page", value: String(BossJobSearchPaginationPolicy.normalizedPage(page))),
            URLQueryItem(name: "pageSize", value: "15")
        ]
        let encoded = normalizedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        referer = "/web/geek/job?query=\(encoded)"
    }
}

struct BossFriendListRequestDescriptor: Equatable, Sendable {
    static let path = "/wapi/zprelation/friend/getGeekFriendList.json"
    let method: BossWebAPIRequest.Method = .POST
    let formItems: [URLQueryItem]

    init(friendIDs: [String], directFriendIDs: [String] = []) throws {
        let friends = Self.normalized(friendIDs)
        let direct = Self.normalized(directFriendIDs)
        guard !friends.isEmpty || !direct.isEmpty else {
            throw BossAPIError.unsupported(
                "BOSS 官方 friend-list 只支持已知 friendIds 的资料补全；当前没有可用会话 ID，本次未发起空参数枚举。"
            )
        }
        var fields: [URLQueryItem] = []
        if !friends.isEmpty {
            fields.append(URLQueryItem(name: "friendIds", value: friends.joined(separator: ",")))
        }
        if !direct.isEmpty {
            fields.append(URLQueryItem(name: "dzFriendIds", value: direct.joined(separator: ",")))
        }
        formItems = fields
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
            .filter { seen.insert($0).inserted }
    }
}

struct BossGreetRequestDescriptor: Equatable, Sendable {
    static let path = "/wapi/zpgeek/friend/add.json"
    let method: BossWebAPIRequest.Method = .POST
    let queryItems: [URLQueryItem]
    let formItems: [URLQueryItem] = []

    init(securityID: String, jobID: String, listID: String) throws {
        guard let securityID = securityID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw BossAPIError.invalidPayload("开聊缺少 securityId，本次请求未发送。")
        }
        guard let jobID = jobID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw BossAPIError.invalidPayload("开聊缺少稳定 jobId，本次请求未发送。")
        }
        guard let listID = listID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw BossAPIError.invalidPayload("开聊缺少 lid，本次请求未发送。")
        }
        queryItems = [
            URLQueryItem(name: "securityId", value: securityID),
            URLQueryItem(name: "jobId", value: jobID),
            URLQueryItem(name: "lid", value: listID)
        ]
    }
}

enum BossSearchRequestPolicy {
    static func normalizedQuery(_ value: String) -> String {
        BossJobSearchPaginationPolicy.normalizedQuery(value)
    }
}

struct BossProfileRequestDescriptor: Equatable, Sendable {
    let operation: BossAPIOperation
    let path: String
    let referer: String
    let isRequired: Bool
}

enum BossProfileRequestPolicy {
    /// 求职状态仅供展示；身份绑定使用稳定资料接口，避免可选状态接口失败阻塞登录。
    static let requests: [BossProfileRequestDescriptor] = [
        BossProfileRequestDescriptor(
            operation: .accountUserInfo,
            path: "/wapi/zpuser/wap/getUserInfo.json",
            referer: "/web/geek/recommend",
            isRequired: true
        ),
        BossProfileRequestDescriptor(
            operation: .accountResumeBase,
            path: "/wapi/zpgeek/resume/baseinfo/query.json",
            referer: "/web/geek/resume",
            isRequired: false
        ),
        BossProfileRequestDescriptor(
            operation: .accountExpectations,
            path: "/wapi/zpgeek/resume/expect/query.json",
            referer: "/web/geek/resume",
            isRequired: false
        ),
        BossProfileRequestDescriptor(
            operation: .accountEducation,
            path: "/wapi/zpgeek/resume/eduexp/query.json",
            referer: "/web/geek/resume",
            isRequired: false
        ),
        BossProfileRequestDescriptor(
            operation: .accountWorkHistory,
            path: "/wapi/zpgeek/resume/workexp/query.json",
            referer: "/web/geek/resume",
            isRequired: false
        ),
        BossProfileRequestDescriptor(
            operation: .accountSelfDescription,
            path: "/wapi/zpgeek/resume/userdesc/query.json",
            referer: "/web/geek/resume",
            isRequired: false
        )
    ]
}

final class BossRequestEpochGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [UUID: UInt64] = [:]

    func token(accountID: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epochs[accountID, default: 0]
    }

    func invalidate(accountID: UUID) {
        lock.lock()
        epochs[accountID, default: 0] &+= 1
        lock.unlock()
    }

    func isCurrent(accountID: UUID, token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return epochs[accountID, default: 0] == token
    }
}

actor BossAPIService {
    static let live = BossAPIService()

    private static let baseURL = URL(string: "https://www.zhipin.com")!
    private let allowsWebFallback: Bool
    private var profileIDs: [UUID: UUID] = [:]
    nonisolated private let requestEpochGate = BossRequestEpochGate()

    init(allowsWebFallback: Bool = true) {
        self.allowsWebFallback = allowsWebFallback
    }

    nonisolated func requestToken(accountID: UUID) -> UInt64 {
        requestEpochGate.token(accountID: accountID)
    }

    nonisolated func invalidateRequests(accountID: UUID) {
        requestEpochGate.invalidate(accountID: accountID)
    }

    func cancelActiveRequests(accountID: UUID) async {
        guard let profileID = profileIDs.removeValue(forKey: accountID) else { return }
        await BossWebAPIService.shared.forget(profileID: profileID)
    }

    func searchJobs(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64,
        query: String,
        cityCode: String,
        page: Int = 1
    ) async throws -> BossAPIResult<[BossRemoteJob]> {
        let descriptor = BossSearchRequestDescriptor(query: query, cityCode: cityCode, page: page)
        guard descriptor.formItems.first?.value?.isEmpty == false else {
            throw BossAPIError.invalidPayload("岗位检索词为空，本次请求未发送。")
        }
        let json = try await requestJSON(
            accountID: accountID,
            profileID: profileID,
            credential: credential,
            requestToken: requestToken,
            operation: .searchJobs,
            path: BossSearchRequestDescriptor.path,
            queryItems: descriptor.queryItems,
            formItems: descriptor.formItems,
            method: descriptor.method,
            referer: descriptor.referer
        )
        let jobs = try BossPayloadParser.validatedJobs(from: json.object)
        if !jobs.isEmpty, jobs.allSatisfy({ $0.salary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw BossAPIError.invalidPayload("BOSS 岗位列表缺少薪资证据，本次结果已失败关闭，避免误判为可投岗位。")
        }
        return BossAPIResult(value: jobs, refreshedCredential: json.credential)
    }

    func dailyInteractions(
        accountID: UUID, profileID: UUID, credential: BossCredential,
        requestToken: UInt64, page: Int, remoteIdentityID: String, resumeExchanges: Bool = false
    ) async throws -> BossAPIResult<(records: [AutomaticGreetingSafetyRecord], hasMore: Bool)> {
        let json = try await requestJSON(
            accountID: accountID, profileID: profileID, credential: credential,
            requestToken: requestToken, operation: resumeExchanges ? .dailyResumeExchanges : .dailyCommunications,
            path: resumeExchanges ? "/wapi/zprelation/resume/geekDeliverList" : "/wapi/zprelation/interaction/geekGetJob",
            queryItems: resumeExchanges ? [URLQueryItem(name: "page", value: String(page))] :
                [URLQueryItem(name: "tag", value: "5"), URLQueryItem(name: "isActive", value: "true"),
                 URLQueryItem(name: "page", value: String(page))],
            referer: "/web/geek/job"
        )
        guard let object = json.object as? [String: Any],
              resumeExchanges || (object["page"] as? NSNumber)?.intValue == page else {
            throw BossAPIError.invalidPayload("每日沟通页码异常，暂缓自动开聊。")
        }
        return BossAPIResult(
            value: try BossPayloadParser.dailyInteractions(from: json.object, remoteIdentityID: remoteIdentityID),
            refreshedCredential: json.credential
        )
    }

    func jobDetail(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64,
        securityID: String,
        listID: String
    ) async throws -> BossAPIResult<BossRemoteJob> {
        var query = [URLQueryItem(name: "securityId", value: securityID)]
        if !listID.isEmpty { query.append(URLQueryItem(name: "lid", value: listID)) }
        let json = try await requestJSON(
            accountID: accountID,
            profileID: profileID,
            credential: credential,
            requestToken: requestToken,
            operation: .jobDetail,
            path: "/wapi/zpgeek/job/detail.json",
            queryItems: query,
            referer: "/web/geek/job"
        )
        guard let detail = BossPayloadParser.jobDetail(from: json.object, securityID: securityID, listID: listID) else {
            throw BossAPIError.invalidPayload("BOSS 未返回可识别的岗位详情。")
        }
        return BossAPIResult(value: detail, refreshedCredential: json.credential)
    }

    func friendSummaries(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64,
        friendIDs: [String] = [],
        directFriendIDs: [String] = []
    ) async throws -> BossAPIResult<[BossFriendSummary]> {
        let descriptor = try BossFriendListRequestDescriptor(
            friendIDs: friendIDs,
            directFriendIDs: directFriendIDs
        )
        let json = try await requestJSON(
            accountID: accountID,
            profileID: profileID,
            credential: credential,
            requestToken: requestToken,
            operation: .friendSummaries,
            path: BossFriendListRequestDescriptor.path,
            queryItems: [],
            formItems: descriptor.formItems,
            method: descriptor.method,
            referer: "/web/geek/chat"
        )
        let summaries: [BossFriendSummary]
        if let object = json.object as? [String: Any], object.isEmpty {
            // 没有最近会话时 BOSS 可返回空 zpData，应视为有效空列表。
            summaries = []
        } else {
            summaries = try BossPayloadParser.validatedFriendSummaries(from: json.object)
        }
        return BossAPIResult(value: summaries, refreshedCredential: json.credential)
    }

    func accountProfile(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64
    ) async throws -> BossAPIResult<BossAccountProfile> {
        var currentCredential = credential
        var payloads: [BossAPIOperation: Any] = [:]
        var warnings: [String] = []
        for request in BossProfileRequestPolicy.requests {
            do {
                let result = try await requestJSON(
                    accountID: accountID,
                    profileID: profileID,
                    credential: currentCredential,
                    requestToken: requestToken,
                    operation: request.operation,
                    path: request.path,
                    queryItems: [],
                    referer: request.referer
                )
                currentCredential = result.credential
                payloads[request.operation] = result.object
            } catch let error as BossAPIError {
                guard !request.isRequired else { throw error }
                if BossServerFailurePolicy.requiresSafetyCooldown(error) { throw error }
                switch error {
                case .httpStatus, .upstream, .invalidPayload, .unsupported:
                    warnings.append(error.localizedDescription)
                case .invalidURL, .authenticationRequired, .webTokenExpired, .manualVerificationRequired:
                    throw error
                }
            }
        }
        guard let profile = BossPayloadParser.accountProfile(
            userInfo: payloads[.accountUserInfo] ?? [String: Any](),
            baseInfo: payloads[.accountResumeBase] ?? [String: Any](),
            expectations: payloads[.accountExpectations] ?? [String: Any](),
            status: [String: Any](),
            education: payloads[.accountEducation] ?? [String: Any](),
            workHistory: payloads[.accountWorkHistory] ?? [String: Any](),
            selfDescription: payloads[.accountSelfDescription] ?? [String: Any]()
        ) else {
            throw BossAPIError.invalidPayload("BOSS 已响应，但没有返回可识别的账号资料。")
        }
        return BossAPIResult(value: profile, refreshedCredential: currentCredential, warnings: warnings)
    }

    /// 先以必需的资料接口核对账号身份，再补齐可选简历信息，避免错绑会话。
    func accountIdentity(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64
    ) async throws -> BossAPIResult<BossAccountProfile> {
        guard let request = BossProfileRequestPolicy.requests.first(where: { $0.isRequired }) else {
            throw BossAPIError.invalidPayload("缺少 BOSS 权威账号身份请求配置。")
        }
        let result = try await requestJSON(
            accountID: accountID,
            profileID: profileID,
            credential: credential,
            requestToken: requestToken,
            operation: request.operation,
            path: request.path,
            queryItems: [],
            referer: request.referer
        )
        guard let profile = BossPayloadParser.accountProfile(
            userInfo: result.object,
            baseInfo: [String: Any](),
            expectations: [String: Any](),
            status: [String: Any](),
            education: [String: Any](),
            workHistory: [String: Any](),
            selfDescription: [String: Any]()
        ) else {
            throw BossAPIError.invalidPayload("BOSS 已响应，但没有返回可验证的账号身份。")
        }
        return BossAPIResult(value: profile, refreshedCredential: result.credential)
    }

    func greet(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64,
        securityID: String,
        jobID: String,
        listID: String
    ) async throws -> BossAPIResult<Void> {
        let descriptor = try BossGreetRequestDescriptor(
            securityID: securityID,
            jobID: jobID,
            listID: listID
        )
        let json = try await requestJSON(
            accountID: accountID,
            profileID: profileID,
            credential: credential,
            requestToken: requestToken,
            operation: .greet,
            path: BossGreetRequestDescriptor.path,
            queryItems: descriptor.queryItems,
            formItems: descriptor.formItems,
            method: descriptor.method,
            referer: "/web/geek/job",
            isWrite: true
        )
        return BossAPIResult(value: (), refreshedCredential: json.credential)
    }

    private func requestJSON(
        accountID: UUID,
        profileID: UUID,
        credential: BossCredential,
        requestToken: UInt64,
        operation: BossAPIOperation,
        path: String,
        queryItems: [URLQueryItem],
        formItems: [URLQueryItem] = [],
        method: BossWebAPIRequest.Method = .GET,
        referer: String,
        isWrite: Bool = false
    ) async throws -> (object: Any, credential: BossCredential) {
        try ensureRequestIsCurrent(accountID: accountID, requestToken: requestToken)
        try ensureRequestIsCurrent(accountID: accountID, requestToken: requestToken)

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw BossAPIError.invalidURL }

        guard allowsWebFallback,
              let warmupURL = URL(string: "https://www.zhipin.com\(referer)") else {
            throw BossAPIError.unsupported("当前请求需要账号隔离的 BOSS WebKit 会话，头部 URLSession 模式已禁用。")
        }
        let formBody = try Self.formEncoded(formItems)
        // 请求取消前保留 Profile，避免已完成的同组请求提前注销它。
        profileIDs[accountID] = profileID
        try ensureRequestIsCurrent(accountID: accountID, requestToken: requestToken)
        let data: Data
        do {
            data = try await BossWebAPIService.shared.requestJSONData(
                profileID: profileID,
                request: BossWebAPIRequest(
                    url: url,
                    method: method,
                    formBody: method == .POST ? formBody : nil
                ),
                warmupURL: warmupURL,
                isStillValid: { [requestEpochGate] in
                    requestEpochGate.isCurrent(accountID: accountID, token: requestToken)
                }
            )
        } catch BossWebAPIError.httpStatus(let status) {
            throw BossAPIError.httpStatus(status)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BossAPIError.invalidPayload(error.localizedDescription)
        }
        try ensureRequestIsCurrent(accountID: accountID, requestToken: requestToken)
        guard let first = data.first, first != Character("<").asciiValue else {
            throw BossAPIError.authenticationRequired
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw BossAPIError.invalidPayload("BOSS 返回数据不是 JSON 对象。")
        }
        let code = (root["code"] as? NSNumber)?.intValue ?? -1
        let message = (root["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case 0:
            break
        case 7:
            throw BossAPIError.authenticationRequired
        case 37, 1011:
            throw BossAPIError.webTokenExpired
        default:
            throw BossServerFailurePolicy.error(
                operation: operation,
                code: code,
                message: message
            )
        }

        let responseCookies = await BossWebSessionService.cookies(profileID: profileID)
        let refreshed = credential.merging(responseCookies)
        return (root["zpData"] ?? root, refreshed)
    }

    private func ensureRequestIsCurrent(accountID: UUID, requestToken: UInt64) throws {
        // 锁内读取是请求的提交界点；先完成的会话失效操作会阻止后续发送。
        guard requestEpochGate.isCurrent(accountID: accountID, token: requestToken) else {
            throw CancellationError()
        }
    }

    private static func formEncoded(_ items: [URLQueryItem]) throws -> String {
        try items.map { item in
            guard let value = item.value,
                  let name = item.name.addingPercentEncoding(withAllowedCharacters: .bossFormAllowed),
                  let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .bossFormAllowed) else {
                throw BossAPIError.invalidPayload("BOSS 表单参数无法编码。")
            }
            return "\(name)=\(encodedValue)"
        }.joined(separator: "&")
    }

}

enum BossAPIError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case authenticationRequired
    case webTokenExpired
    case manualVerificationRequired(operation: BossAPIOperation, code: Int, message: String)
    case unsupported(String)
    case upstream(operation: BossAPIOperation, code: Int, message: String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "BOSS 请求地址无效。"
        case .httpStatus(let code): "BOSS 服务返回 HTTP \(code)。"
        case .authenticationRequired: "BOSS 登录态已失效，请重新扫码。"
        case .webTokenExpired: "BOSS 网页安全令牌已过期，请打开账号管理页刷新官方页面后重试。"
        case .manualVerificationRequired(let operation, let code, let message):
            "BOSS \(operation.rawValue)要求本人完成安全验证（\(code)）：\(message)"
        case .unsupported(let message): message
        case .upstream(let operation, let code, let message):
            "BOSS \(operation.rawValue)返回错误 \(code)：\(message)"
        case .invalidPayload(let message): message
        }
    }
}

private extension CharacterSet {
    static let bossFormAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

enum BossPayloadParser {
    private static let listKeys = ["jobList", "cardList", "jobs", "items", "list", "results"]

    static func dailyInteractions(
        from payload: Any, remoteIdentityID: String
    ) throws -> (records: [AutomaticGreetingSafetyRecord], hasMore: Bool) {
        guard let object = payload as? [String: Any],
              let rows = object["cardList"] as? [[String: Any]],
              let hasMore = object["hasMore"] as? Bool,
              !rows.isEmpty || !hasMore else {
            throw BossAPIError.invalidPayload("每日互动列表结构异常，无法确认今日统计。")
        }
        var records: [AutomaticGreetingSafetyRecord] = []
        for row in rows {
            guard let jobID = (row["encryptJobId"] as? String)?.nilIfBlank,
                  let time = row["happenTime"] as? NSNumber,
                  CFGetTypeID(time) != CFBooleanGetTypeID(),
                  time.doubleValue.isFinite, time.doubleValue > 0 else {
                throw BossAPIError.invalidPayload("每日互动记录缺少岗位或时间证据，无法确认今日统计。")
            }
            records.append(AutomaticGreetingSafetyRecord(
                remoteIdentityID: remoteIdentityID, remoteJobID: jobID,
                attemptedAt: Date(timeIntervalSince1970: time.doubleValue / 1000),
                remoteRecipientID: (row["encryptBossId"] as? String)?.nilIfBlank
            ))
        }
        guard zip(records, records.dropFirst()).allSatisfy({ $0.attemptedAt >= $1.attemptedAt }) else {
            throw BossAPIError.invalidPayload("每日互动列表顺序异常，无法确认今日统计。")
        }
        return (records, hasMore)
    }

    static func jobs(from payload: Any) -> [BossRemoteJob] {
        guard let rows = findList(in: payload, keys: listKeys, depth: 0) else { return [] }
        let pageListID = deepString(payload, keys: ["lid", "listId"])
        return rows.compactMap { remoteJob(from: $0, fallbackListID: pageListID) }
    }

    static func validatedJobs(from payload: Any) throws -> [BossRemoteJob] {
        guard let rows = findNamedList(in: payload, keys: listKeys, depth: 0) else {
            throw BossAPIError.invalidPayload("BOSS 岗位列表结构已变化，本次同步未把异常响应当作空结果。")
        }
        let pageListID = deepString(payload, keys: ["lid", "listId"])
        let jobs = rows.compactMap { remoteJob(from: $0, fallbackListID: pageListID) }
        if !rows.isEmpty, jobs.isEmpty {
            throw BossAPIError.invalidPayload("BOSS 返回了岗位记录，但缺少可识别的岗位与公司字段。")
        }
        return jobs
    }

    static func jobDetail(from payload: Any, securityID: String, listID: String) -> BossRemoteJob? {
        guard let object = firstDictionary(in: payload) else { return nil }
        var result = remoteJob(from: object, fallbackListID: listID) ?? BossRemoteJob(
            remoteJobID: "",
            securityID: securityID,
            listID: listID,
            title: "",
            company: "",
            location: "",
            salary: "",
            experience: "",
            education: "",
            description: "",
            recruiterName: "",
            url: ""
        )
        result.securityID = result.securityID.nilIfBlank ?? securityID
        result.description = deepString(payload, keys: [
            "postDescription", "jobDescription", "description", "jobDesc",
            "detailText", "jobSecText", "jobContent", "positionDescription"
        ])
        if result.title.isEmpty { result.title = deepString(payload, keys: ["jobName", "positionName", "title"]) }
        if result.company.isEmpty { result.company = deepString(payload, keys: ["brandName", "companyName", "company"]) }
        if result.salary.isEmpty { result.salary = deepString(payload, keys: ["salaryDesc", "salary", "jobSalary"]) }
        if result.location.isEmpty {
            result.location = BossCityResolver.displayText(
                for: deepString(payload, keys: ["address", "jobAddress", "locationName", "cityName"])
            )
        }
        if result.recruiterName.isEmpty {
            result.recruiterName = deepString(payload, keys: ["bossName", "recruiterName", "bossNickName"])
        }
        if result.recruiterTitle.isEmpty {
            result.recruiterTitle = deepString(payload, keys: ["bossTitle", "recruiterTitle", "bossPosition"])
        }
        if result.industry.isEmpty {
            result.industry = industryText(from: payload)
        }
        if result.companySize.isEmpty {
            result.companySize = deepString(payload, keys: ["scaleName", "brandScaleName", "companySize", "companyScale"])
        }
        if result.financingStage.isEmpty {
            result.financingStage = deepString(payload, keys: ["stageName", "brandStageName", "financingStage", "financeStage"])
        }
        if result.tags.isEmpty {
            result.tags = deepStrings(payload, keys: ["skills", "jobLabels", "jobTags", "skillsList", "showSkills"])
        }
        if result.benefits.isEmpty {
            result.benefits = deepStrings(payload, keys: ["welfareList", "welfare", "benefits", "jobBenefits"])
        }
        return result
    }

    static func friendSummaries(from payload: Any) -> [BossFriendSummary] {
        guard let rows = findList(in: payload, keys: ["friendList", "friends", "list"], depth: 0) else { return [] }
        return friendSummaries(from: rows)
    }

    static func validatedFriendSummaries(from payload: Any) throws -> [BossFriendSummary] {
        if let object = payload as? [String: Any], object.isEmpty {
            return []
        }
        guard let rows = findNamedList(in: payload, keys: ["friendList", "friends", "list"], depth: 0) else {
            throw BossAPIError.invalidPayload("BOSS 沟通列表结构已变化，本次同步未把异常响应当作没有消息。")
        }
        let summaries = friendSummaries(from: rows)
        if !rows.isEmpty, summaries.isEmpty {
            throw BossAPIError.invalidPayload("BOSS 返回了沟通记录，但缺少稳定的招聘方会话标识。")
        }
        return summaries
    }

    private static func friendSummaries(from rows: [[String: Any]]) -> [BossFriendSummary] {
        return rows.compactMap { row in
            let friendID = deepString(row, keys: ["friendId", "uid", "bossId"])
            let source = deepString(row, keys: ["friendSource", "source"])
            let latest = deepString(row, keys: ["lastText", "lastMsg", "lastMessage", "content"])
            guard !friendID.isEmpty else { return nil }
            let timestamp = deepDouble(row, keys: ["updateTime", "lastTS", "time"])
            let unreadCount = Int(deepDouble(row, keys: ["num", "unreadCount", "count"]))
            let lastMessage = (row["lastMsg"] as? [String: Any]) ?? (row["lastMessage"] as? [String: Any])
            let fromID = lastMessage.map { deepString($0, keys: ["fromId", "senderId", "uid"]) } ?? ""
            let toID = lastMessage.map { deepString($0, keys: ["toId", "recipientId", "targetId"]) } ?? ""
            let lastMessageID = (lastMessage.map { deepString($0, keys: ["mid", "messageId"]) } ?? "")
                .nilIfBlank ?? deepString(row, keys: ["lastMsgId", "mid", "messageId"])
            // 缺少发送方字段时，正未读数仅支持来信展示；零未读不能确定方向。
            let incoming: Bool? = fromID.isEmpty ? (unreadCount > 0 ? true : nil) : fromID == friendID
            return BossFriendSummary(
                conversationID: "boss-\(friendID)-\(source)",
                recruiterName: deepString(row, keys: ["name", "bossName", "recruiterName"]),
                company: deepString(row, keys: ["brandName", "companyName", "company"]),
                jobTitle: deepString(row, keys: ["jobName", "positionName", "jobTitle"]),
                latestText: latest,
                unreadCount: unreadCount,
                // 缺少时间戳时保持回退值稳定，避免轮询制造新消息。
                updatedAt: timestamp > 0
                    ? Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp)
                    : Date(timeIntervalSince1970: 0),
                securityID: deepString(row, keys: ["securityId"]),
                listID: deepString(row, keys: ["lid", "listId"]),
                latestIsIncoming: incoming,
                encryptedBossID: firstNonEmpty([
                    deepString(row, keys: ["encryptBossId", "encryptUserId", "encryptUid"]),
                    friendID
                ]),
                friendSource: source,
                groupID: deepString(row, keys: ["gid", "groupId"]),
                latestRemoteMID: lastMessageID,
                latestSenderID: fromID,
                latestRecipientID: toID,
                latestMessageType: lastMessage.map { Int(deepDouble($0, keys: ["type", "messageType"])) },
                latestActionAID: lastMessage.map { message in
                    let value = Int(deepDouble(message, keys: ["aid", "actionId", "actionID"]))
                    return value > 0 ? value : nil
                } ?? nil,
                latestScene: lastMessage.map { message in
                    let value = Int(deepDouble(message, keys: ["scene"]))
                    return value > 0 ? value : nil
                } ?? nil,
                latestDirectionIsAuthoritative: !fromID.isEmpty,
                jobSalary: deepString(row, keys: ["salaryDesc", "salary", "jobSalary", "salaryName"]),
                jobLocation: BossCityResolver.displayText(
                    for: [
                        deepString(row, keys: ["cityName", "jobCity", "locationName", "city"]),
                        deepString(row, keys: ["areaDistrict", "district", "businessDistrict", "area"])
                    ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                )
            )
        }
    }

    static func accountProfile(
        userInfo: Any,
        baseInfo: Any,
        expectations: Any,
        status: Any,
        education: Any = [String: Any](),
        workHistory: Any = [String: Any](),
        selfDescription: Any = [String: Any]()
    ) -> BossAccountProfile? {
        let name = firstNonEmpty([
            deepString(userInfo, keys: ["name", "geekName", "userName", "nickName"]),
            deepString(baseInfo, keys: ["name", "geekName", "userName"])
        ])
        let remoteID = firstNonEmpty([
            deepString(userInfo, keys: ["encryptUserId", "userId", "geekId", "uid"]),
            deepString(baseInfo, keys: ["encryptUserId", "userId", "geekId", "uid"])
        ])
        let avatar = firstNonEmpty([
            deepString(userInfo, keys: ["avatar", "avatarUrl", "largeAvatar", "headImg"]),
            deepString(baseInfo, keys: ["avatar", "avatarUrl", "headImg"])
        ])
        let title = deepString(baseInfo, keys: ["positionName", "currentPosition", "jobName", "position"])
        let city = BossCityResolver.displayText(
            for: deepString(baseInfo, keys: ["cityName", "city", "locationName"])
        )
        let workExperience = deepString(baseInfo, keys: ["workYearDesc", "workYears", "experienceName", "workExperience"])
        let jobStatus = deepString(status, keys: ["statusDesc", "jobStatusDesc", "statusName", "expectStatusDesc"])
        let educationSummary = firstProfileItemSummary(
            in: education,
            listKeys: ["eduExpList", "educationList", "educationExperienceList", "list"],
            fieldKeys: [
                ["schoolName", "school"],
                ["majorName", "major"],
                ["degreeName", "degree", "educationName"]
            ]
        )
        let recentWorkSummary = firstProfileItemSummary(
            in: workHistory,
            listKeys: ["workExpList", "workExperienceList", "workList", "list"],
            fieldKeys: [
                ["companyName", "company", "brandName"],
                ["positionName", "jobName", "title"]
            ]
        )
        let selfDescriptionText = firstNonEmpty([
            deepString(selfDescription, keys: ["userDescription", "userDesc", "selfDescription", "description", "content"]),
            deepString(baseInfo, keys: ["userDescription", "userDesc", "selfDescription"])
        ])

        var expectationLabels: [String] = []
        if let rows = findList(in: expectations, keys: ["expectList", "jobExpectList", "expectations", "list"], depth: 0) {
            for row in rows {
                let label = [
                    deepString(row, keys: ["positionName", "jobName", "expectPositionName"]),
                    BossCityResolver.displayText(
                        for: deepString(row, keys: ["cityName", "locationName", "expectCityName"])
                    ),
                    deepString(row, keys: ["salaryDesc", "salary", "expectSalaryDesc"])
                ].filter { !$0.isEmpty }.joined(separator: " · ")
                if !label.isEmpty, !expectationLabels.contains(label) { expectationLabels.append(label) }
            }
        }
        if expectationLabels.isEmpty {
            let fallback = [
                deepString(expectations, keys: ["positionName", "jobName", "expectPositionName"]),
                BossCityResolver.displayText(
                    for: deepString(expectations, keys: ["cityName", "locationName", "expectCityName"])
                ),
                deepString(expectations, keys: ["salaryDesc", "salary", "expectSalaryDesc"])
            ].filter { !$0.isEmpty }.joined(separator: " · ")
            if !fallback.isEmpty { expectationLabels = [fallback] }
        }

        guard !name.isEmpty || !remoteID.isEmpty || !title.isEmpty || !expectationLabels.isEmpty ||
              !jobStatus.isEmpty || !educationSummary.isEmpty || !recentWorkSummary.isEmpty || !selfDescriptionText.isEmpty else {
            return nil
        }
        return BossAccountProfile(
            remoteID: remoteID,
            name: name,
            avatarURL: avatar,
            currentTitle: title,
            city: city,
            workExperience: workExperience,
            expectations: expectationLabels,
            jobStatus: jobStatus,
            syncedAt: Date(),
            educationSummary: educationSummary.nilIfBlank,
            recentWorkSummary: recentWorkSummary.nilIfBlank,
            selfDescription: selfDescriptionText.nilIfBlank
        )
    }

    private static func firstProfileItemSummary(
        in payload: Any,
        listKeys: [String],
        fieldKeys: [[String]]
    ) -> String {
        let source: Any
        if let row = findList(in: payload, keys: listKeys, depth: 0)?.first {
            source = row
        } else {
            source = payload
        }
        return fieldKeys
            .map { deepString(source, keys: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func industryText(from payload: Any) -> String {
        let name = BossIndustryResolver.displayText(for: deepString(payload, keys: ["industryName", "brandIndustryName"]))
        if !name.isEmpty { return name }
        return BossIndustryResolver.displayText(for: deepString(payload, keys: ["industry", "brandIndustry"]))
    }

    private static func remoteJob(from row: [String: Any], fallbackListID: String) -> BossRemoteJob? {
        let title = deepString(row, keys: ["jobName", "positionName", "title", "name"])
        let company = deepString(row, keys: ["brandName", "companyName", "company", "brand"])
        guard !title.isEmpty || !company.isEmpty else { return nil }
        let securityID = deepString(row, keys: ["securityId", "security_id"])
        let explicitRemoteJobID = deepString(
            row,
            keys: ["encryptJobId", "encrypt_job_id", "jobId", "job_id"]
        )
        let listID = deepString(row, keys: ["lid", "listId", "list_id"]).nilIfBlank ?? fallbackListID
        let url = deepString(row, keys: ["jobUrl", "url", "href", "detailUrl"])
        let officialURL: String
        if !url.isEmpty {
            officialURL = url.hasPrefix("http") ? url : "https://www.zhipin.com\(url)"
        } else if !securityID.isEmpty {
            let detailPath = explicitRemoteJobID.nilIfBlank
                .map { "https://www.zhipin.com/job_detail/\($0).html" }
                ?? "https://www.zhipin.com/job_detail/"
            var components = URLComponents(string: detailPath)!
            components.queryItems = [URLQueryItem(name: "securityId", value: securityID), URLQueryItem(name: "lid", value: listID)]
            officialURL = components.url?.absoluteString ?? ""
        } else {
            officialURL = ""
        }
        let pathRemoteJobID: String = {
            guard let path = URL(string: officialURL)?.path,
                  path.contains("/job_detail/"),
                  let slug = path.split(separator: "/").last else { return "" }
            let value = String(slug)
            return value.hasSuffix(".html") ? String(value.dropLast(5)) : value
        }()
        let remoteJobID = explicitRemoteJobID.nilIfBlank ?? pathRemoteJobID
        return BossRemoteJob(
            remoteJobID: remoteJobID,
            securityID: securityID,
            listID: listID,
            title: title,
            company: company,
            location: BossCityResolver.displayText(for: [
                deepString(row, keys: ["cityName", "city", "location"]),
                deepString(row, keys: ["areaDistrict", "district", "area"])
            ].filter { !$0.isEmpty }.joined(separator: " · ")),
            salary: deepString(row, keys: ["salaryDesc", "salary", "salaryText", "jobSalary"]),
            experience: deepString(row, keys: ["jobExperience", "experience", "experienceName"]),
            education: deepString(row, keys: ["jobDegree", "degree", "education"]),
            description: deepString(row, keys: ["postDescription", "jobDescription", "jobDesc", "jobSecText", "jobContent"]),
            recruiterName: deepString(row, keys: ["bossName", "boss", "recruiterName"]),
            url: officialURL,
            recruiterTitle: deepString(row, keys: ["bossTitle", "recruiterTitle", "bossPosition"]),
            industry: industryText(from: row),
            companySize: deepString(row, keys: ["scaleName", "brandScaleName", "companySize", "companyScale"]),
            financingStage: deepString(row, keys: ["stageName", "brandStageName", "financingStage", "financeStage"]),
            tags: deepStrings(row, keys: ["skills", "jobLabels", "jobTags", "skillsList", "showSkills"]),
            benefits: deepStrings(row, keys: ["welfareList", "welfare", "benefits", "jobBenefits"])
        )
    }

    private static func findList(in node: Any, keys: [String], depth: Int) -> [[String: Any]]? {
        guard depth <= 7 else { return nil }
        if let rows = node as? [[String: Any]], !rows.isEmpty { return rows }
        guard let dictionary = node as? [String: Any] else { return nil }
        for key in keys {
            if let rows = dictionary[key] as? [[String: Any]], !rows.isEmpty { return rows }
        }
        for value in dictionary.values {
            if let found = findList(in: value, keys: keys, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func findNamedList(in node: Any, keys: [String], depth: Int) -> [[String: Any]]? {
        guard depth <= 7 else { return nil }
        if let dictionary = node as? [String: Any] {
            for key in keys where dictionary.keys.contains(key) {
                if let rows = dictionary[key] as? [[String: Any]] { return rows }
                if let values = dictionary[key] as? [Any] {
                    let rows = values.compactMap { $0 as? [String: Any] }
                    if rows.count == values.count { return rows }
                }
            }
            for value in dictionary.values {
                if let found = findNamedList(in: value, keys: keys, depth: depth + 1) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = findNamedList(in: value, keys: keys, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func firstDictionary(in node: Any, depth: Int = 0) -> [String: Any]? {
        guard depth <= 7 else { return nil }
        if let dictionary = node as? [String: Any] { return dictionary }
        if let array = node as? [Any] {
            for value in array {
                if let found = firstDictionary(in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func deepString(_ node: Any, keys: [String], depth: Int = 0) -> String {
        guard depth <= 6 else { return "" }
        if let dictionary = node as? [String: Any] {
            for key in keys {
                if let value = dictionary[key] {
                    if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return string.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let number = value as? NSNumber { return number.stringValue }
                }
            }
            for value in dictionary.values {
                let found = deepString(value, keys: keys, depth: depth + 1)
                if !found.isEmpty { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                let found = deepString(value, keys: keys, depth: depth + 1)
                if !found.isEmpty { return found }
            }
        }
        return ""
    }

    private static func deepDouble(_ node: Any, keys: [String], depth: Int = 0) -> Double {
        guard depth <= 6 else { return 0 }
        if let dictionary = node as? [String: Any] {
            for key in keys {
                if let number = dictionary[key] as? NSNumber { return number.doubleValue }
                if let string = dictionary[key] as? String, let number = Double(string) { return number }
            }
            for value in dictionary.values {
                let found = deepDouble(value, keys: keys, depth: depth + 1)
                if found != 0 { return found }
            }
        }
        return 0
    }

    private static func deepStrings(_ node: Any, keys: [String], depth: Int = 0) -> [String] {
        guard depth <= 6 else { return [] }
        if let dictionary = node as? [String: Any] {
            for key in keys where dictionary.keys.contains(key) {
                let values = strings(from: dictionary[key])
                if !values.isEmpty { return values }
            }
            for value in dictionary.values {
                let found = deepStrings(value, keys: keys, depth: depth + 1)
                if !found.isEmpty { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                let found = deepStrings(value, keys: keys, depth: depth + 1)
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    private static func strings(from value: Any?) -> [String] {
        let rawValues: [String]
        if let strings = value as? [String] {
            rawValues = strings
        } else if let rows = value as? [[String: Any]] {
            rawValues = rows.map {
                deepString($0, keys: ["name", "label", "text", "content", "value"])
            }
        } else if let string = value as? String {
            rawValues = string.components(separatedBy: CharacterSet(charactersIn: ",，、;"))
        } else {
            rawValues = []
        }
        var seen = Set<String>()
        return rawValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func firstNonEmpty(_ values: [String]) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
}

private extension Character {
    var asciiValue: UInt8? { String(self).utf8.first }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
