import Foundation

struct BossStoredCookie: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    var isSessionOnly: Bool?
    var sameSitePolicy: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        isSessionOnly = cookie.isSessionOnly
        sameSitePolicy = cookie.sameSitePolicy?.rawValue
    }

    var httpCookie: HTTPCookie? {
        guard expiresAt.map({ $0 > Date() }) ?? true else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
            .secure: isSecure ? "TRUE" : "FALSE"
        ]
        if let expiresAt { properties[.expires] = expiresAt }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if isSessionOnly == true { properties[.discard] = "TRUE" }
        if let sameSitePolicy { properties[.sameSitePolicy] = sameSitePolicy }
        return HTTPCookie(properties: properties)
    }
}

struct BossCredential: Codable, Hashable, Sendable {
    static let identityCookieNames: Set<String> = ["wt2", "zp_at"]
    /// 请求使用账号自己的 WebKit Profile；wbg 可选，但 BOSS 下发的所有 Cookie 均保留并合并。
    static let automationCookieNames: Set<String> = ["__zp_stoken__", "wt2", "zp_at"]

    var cookies: [BossStoredCookie]
    var savedAt: Date

    init(cookies: [HTTPCookie], savedAt: Date = Date()) {
        let current = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let isBossDomain = domain == "zhipin.com" || domain.hasSuffix(".zhipin.com")
            let isCurrent = cookie.expiresDate.map { $0 > Date() } ?? true
            return isBossDomain && isCurrent && !cookie.value.isEmpty
        }
        var unique: [String: HTTPCookie] = [:]
        for cookie in current {
            unique[Self.cookieKey(cookie)] = cookie
        }
        self.cookies = unique.values.map(BossStoredCookie.init).sorted {
            if $0.domain == $1.domain { return $0.name < $1.name }
            return $0.domain < $1.domain
        }
        self.savedAt = savedAt
    }

    var httpCookies: [HTTPCookie] {
        cookies.compactMap(\.httpCookie).filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return domain == "zhipin.com" || domain.hasSuffix(".zhipin.com")
        }
    }

    var hasIdentity: Bool {
        let names = Set(httpCookies.map(\.name))
        return names.isSuperset(of: Self.identityCookieNames)
    }

    var isAutomationReady: Bool {
        Set(httpCookies.map(\.name)).isSuperset(of: Self.automationCookieNames)
    }

    /// 仅在内存中用指纹检测登录 Cookie 变化，指纹不记录 Cookie 原值。
    var identityFingerprint: String {
        let material = cookies
            .filter { Self.identityCookieNames.contains($0.name) }
            .map { "\($0.name)|\($0.domain.lowercased())|\($0.path)|\($0.value)" }
            .sorted()
            .joined(separator: "\u{1F}")
        return StableIdentifier.fnv1a64(material)
    }

    /// 保存同一 Profile 的完整 Cookie 快照；请求范围和动态轮换由 WebKit 决定。
    var connectorCookies: [HTTPCookie] {
        httpCookies
    }

    func merging(_ newCookies: [HTTPCookie]) -> BossCredential {
        BossCredential(cookies: httpCookies + newCookies)
    }

    private static func cookieKey(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)|\(cookie.domain.lowercased())|\(cookie.path)"
    }
}

enum BossCredentialVaultError: LocalizedError {
    case symbolicLink(URL)
    case incompleteCredential

    var errorDescription: String? {
        switch self {
        case .symbolicLink(let url):
            "拒绝读写符号链接会话文件：\(url.path)"
        case .incompleteCredential:
            "BOSS 未返回可恢复的完整登录会话。"
        }
    }
}

final class BossCredentialVault: @unchecked Sendable {
    static let live: BossCredentialVault = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BossCredentialVault(directoryURL: base.appendingPathComponent("BossPilot/Sessions", isDirectory: true))
    }()

    private let directoryURL: URL
    private let lock = NSLock()

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func load(profileID: UUID) throws -> BossCredential? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(directoryURL)
        try rejectSymbolicLink(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let credential = try decoder.decode(BossCredential.self, from: Data(contentsOf: url))
        guard credential.hasIdentity else {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        return credential
    }

    func save(_ credential: BossCredential, profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard credential.hasIdentity else { throw BossCredentialVaultError.incompleteCredential }
        try prepareDirectory()
        let url = fileURL(profileID: profileID)
        if FileManager.default.fileExists(atPath: url.path) {
            try rejectSymbolicLink(url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(credential).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try rejectSymbolicLink(directoryURL)
        try rejectSymbolicLink(url)
        try FileManager.default.removeItem(at: url)
    }

    func filePermissions(profileID: UUID) throws -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func prepareDirectory() throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try rejectSymbolicLink(directoryURL)
        } else {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func fileURL(profileID: UUID) -> URL {
        directoryURL.appendingPathComponent(profileID.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw BossCredentialVaultError.symbolicLink(url)
        }
    }
}
