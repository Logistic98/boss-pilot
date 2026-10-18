import Foundation
import WebKit

enum BossBrowserIdentity {
    /// 扫码和隐藏请求统一使用 Safari/WebKit 身份，避免伪装 Chrome 导致身份不一致。
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}

enum BossWebSessionService {
    private static let authenticatedCookieNames: Set<String> = ["wt2", "zp_at"]
    @MainActor private static var persistentStores: [UUID: WKWebsiteDataStore] = [:]
    @MainActor private static var retiredProfileIDs: Set<UUID> = []

    @MainActor
    static func dataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if let existing = persistentStores[profileID] { return existing }
        if retiredProfileIDs.contains(profileID) {
            return .nonPersistent()
        }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        persistentStores[profileID] = store
        return store
    }

    static func isAuthenticated(cookies: [HTTPCookie]) -> Bool {
        let names = Set(cookies.compactMap { cookie -> String? in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let isBossDomain = domain == "zhipin.com" || domain.hasSuffix(".zhipin.com")
            return isBossDomain ? cookie.name : nil
        })
        return names.isSuperset(of: authenticatedCookieNames)
    }

    @MainActor
    static func isAuthenticated(profileID: UUID) async -> Bool {
        isAuthenticated(cookies: await cookies(profileID: profileID))
    }

    @MainActor
    static func cookies(profileID: UUID) async -> [HTTPCookie] {
        let cookieStore = dataStore(for: profileID).httpCookieStore
        return await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    static func importCookies(_ cookies: [HTTPCookie], profileID: UUID) async {
        guard !retiredProfileIDs.contains(profileID) else { return }
        let cookieStore = dataStore(for: profileID).httpCookieStore
        // 导入 Cookie 仅做合并；持久快照可能落后于 WebKit，不能删除快照中缺失的动态状态。
        for cookie in cookies where isBossDomain(cookie.domain) {
            guard !retiredProfileIDs.contains(profileID) else { return }
            await withCheckedContinuation { continuation in
                cookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    @MainActor
    static func clear(dataStore: WKWebsiteDataStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    @MainActor
    static func removePersistentStore(for profileID: UUID) async throws {
        retiredProfileIDs.insert(profileID)
        releaseCachedStore(for: profileID)
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            try Task.checkCancellation()
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: profileID)
                return
            } catch {
                let failure = error as NSError
                // WebKit 用固定文案的未知错误表示忙碌状态，没有独立错误码。
                guard failure.domain == "WKWebSiteDataStore",
                      failure.localizedDescription == "Data store is in use" else { throw error }
                guard ContinuousClock.now < deadline else { throw BossWebSessionError.storeStillInUse }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @MainActor
    static func releaseCachedStore(for profileID: UUID) {
        persistentStores[profileID] = nil
    }

    @MainActor
    static func beginRetiring(profileID: UUID) {
        retiredProfileIDs.insert(profileID)
    }

    private static func isBossDomain(_ rawDomain: String) -> Bool {
        let domain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return domain == "zhipin.com" || domain.hasSuffix(".zhipin.com")
    }

}

enum BossWebSessionError: LocalizedError {
    case storeStillInUse

    var errorDescription: String? {
        "账号网页数据仍被占用。请关闭该账号的网页窗口；若同时运行了多个 BossPilot，请退出其他实例后重试删除。"
    }
}
