import Foundation
import WebKit

enum BossWebAPIError: LocalizedError {
    case pageLoadFailed(String)
    case pageLoadTimedOut
    case invalidBridgeResponse
    case httpStatus(Int)
    case requestInProgress

    var errorDescription: String? {
        switch self {
        case .pageLoadFailed(let message): "BOSS 官方页面加载失败：\(message)"
        case .pageLoadTimedOut: "BOSS 官方页面准备超时。"
        case .invalidBridgeResponse: "BOSS 官方页面返回了无法识别的数据。"
        case .httpStatus(let status): "BOSS 官方页面请求失败（HTTP \(status)）。"
        case .requestInProgress: "该账号仍有网页请求正在执行，请稍后重试。"
        }
    }
}

struct BossWebAPIRequest: Equatable, Sendable {
    enum Method: String, Equatable, Sendable {
        case GET
        case POST
    }

    let url: URL
    let method: Method
    let formBody: String?

    init(url: URL, method: Method, formBody: String? = nil) {
        self.url = url
        self.method = method
        self.formBody = formBody
    }
}

/// 在账号独立 WebKit Profile 中执行同源请求，由浏览器维护请求头、Cookie 和网关令牌。
@MainActor
final class BossWebAPIService {
    static let shared = BossWebAPIService()

    private var clients: [UUID: BossWebAPIClient] = [:]

    func requestJSONData(
        profileID: UUID,
        request: BossWebAPIRequest,
        warmupURL: URL,
        isStillValid: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Data {
        guard isStillValid() else { throw CancellationError() }
        let client: BossWebAPIClient
        if let existing = clients[profileID], !existing.isInvalidated {
            client = existing
        } else {
            let created = BossWebAPIClient(profileID: profileID)
            clients[profileID] = created
            client = created
        }
        if client.requiresPreparation(at: warmupURL) {
            try await BossNetworkPacingGate.shared.wait(
                isWrite: false,
                discriminator: "web-warmup|\(profileID.uuidString)|\(warmupURL.path)",
                isStillValid: {
                    guard isStillValid() else { return false }
                    return await !client.isInvalidated
                }
            )
        }
        guard isStillValid() else { throw CancellationError() }
        try await client.prepare(at: warmupURL)
        try await BossNetworkPacingGate.shared.wait(
            isWrite: request.method == .POST,
            discriminator: "web-api|\(profileID.uuidString)|\(request.url.path)",
            isStillValid: {
                guard isStillValid() else { return false }
                return await !client.isInvalidated
            }
        )
        guard isStillValid() else { throw CancellationError() }
        return try await client.requestJSONData(request: request)
    }

    func requestJSONData(profileID: UUID, url: URL, warmupURL: URL) async throws -> Data {
        try await requestJSONData(
            profileID: profileID,
            request: BossWebAPIRequest(url: url, method: .GET),
            warmupURL: warmupURL
        )
    }

    func forget(profileID: UUID) {
        clients.removeValue(forKey: profileID)?.invalidate()
    }
}

@MainActor
final class BossWebAPIClient: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let bridgeName = "bossPilotReadBridge"
    private(set) var webView: WKWebView!
    private var prepared = false
    private(set) var isInvalidated = false
    private var preparationContinuation: CheckedContinuation<Void, Error>?
    private var preparationTimeout: Task<Void, Never>?
    private var requestContinuation: CheckedContinuation<Data, Error>?
    private var requestTimeout: Task<Void, Never>?
    private var requestID: String?

    init(profileID: UUID) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BossWebSessionService.dataStore(for: profileID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        super.init()
        configuration.userContentController.add(self, name: Self.bridgeName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = BossBrowserIdentity.userAgent
        webView.navigationDelegate = self
    }

    func requiresPreparation(at url: URL) -> Bool {
        !prepared ||
            webView.url?.host?.hasSuffix("zhipin.com") != true ||
            webView.url?.path != url.path
    }

    func prepare(at url: URL) async throws {
        guard !isInvalidated else { throw CancellationError() }
        guard OfficialBossLinkService.isOfficialURL(url) else {
            throw BossWebAPIError.invalidBridgeResponse
        }
        if prepared,
           webView.url?.host?.hasSuffix("zhipin.com") == true,
           webView.url?.path == url.path {
            return
        }
        if preparationContinuation != nil {
            while preparationContinuation != nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !isInvalidated else { throw CancellationError() }
            if prepared,
               webView.url?.host?.hasSuffix("zhipin.com") == true,
               webView.url?.path == url.path {
                return
            }
        }
        guard requestContinuation == nil else { throw BossWebAPIError.requestInProgress }
        prepared = false
        try await withCheckedThrowingContinuation { continuation in
            preparationContinuation = continuation
            let request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 20
            )
            webView.load(request)
            preparationTimeout?.cancel()
            preparationTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                } catch {
                    return
                }
                guard let self, let pending = self.preparationContinuation else { return }
                self.preparationContinuation = nil
                self.invalidate()
                pending.resume(throwing: BossWebAPIError.pageLoadTimedOut)
            }
        }
    }

    func requestJSONData(request: BossWebAPIRequest) async throws -> Data {
        guard !isInvalidated else { throw CancellationError() }
        guard requestContinuation == nil else { throw BossWebAPIError.requestInProgress }
        guard OfficialBossLinkService.isOfficialURL(request.url), prepared else {
            throw BossWebAPIError.invalidBridgeResponse
        }
        let encodedData = try JSONSerialization.data(withJSONObject: [
            request.url.absoluteString,
            request.method.rawValue,
            request.formBody ?? ""
        ])
        guard let encodedRequest = String(data: encodedData, encoding: .utf8) else {
            throw BossWebAPIError.invalidBridgeResponse
        }
        let identifier = UUID().uuidString
        let script = """
        (() => {
          const request = \(encodedRequest);
          const url = new URL(request[0], window.location.origin);
          if (url.origin !== window.location.origin || !url.hostname.endsWith('zhipin.com')) {
            throw new Error('cross-origin request rejected');
          }
          url.searchParams.set('_', String(Date.now()));
          const headers = {
            'Accept': 'application/json, text/plain, */*',
            'X-Requested-With': 'XMLHttpRequest',
            'traceId': (window.crypto && typeof window.crypto.randomUUID === 'function')
              ? window.crypto.randomUUID().replaceAll('-', '')
              : String(Date.now()) + Math.random().toString(16).slice(2)
          };
          const pageToken = window._PAGE && window._PAGE.token
            ? String(window._PAGE.token).split('|')[0]
            : '';
          if (pageToken) headers.token = pageToken;
          const bstMatch = document.cookie.match(/(?:^|;\\s*)bst=([^;]+)/);
          if (bstMatch && bstMatch[1]) headers.zp_token = decodeURIComponent(bstMatch[1]);
          const options = {
            method: request[1],
          credentials: 'include',
            headers
          };
          if (request[1] === 'POST') {
            headers['Content-Type'] = 'application/x-www-form-urlencoded';
            options.body = request[2];
          }
          return fetch(url.toString(), options);
        })().then(async response => {
            const payload = JSON.stringify({ id: '\(identifier)', status: response.status, body: await response.text() });
            window.webkit.messageHandlers.\(Self.bridgeName).postMessage(payload);
          }).catch(error => {
            const payload = JSON.stringify({ id: '\(identifier)', error: String(error && error.message ? error.message : error) });
            window.webkit.messageHandlers.\(Self.bridgeName).postMessage(payload);
          });
        null
        """
        let wrapperData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            requestContinuation = continuation
            requestID = identifier
            requestTimeout?.cancel()
            requestTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                } catch {
                    return
                }
                guard let self, self.requestID == identifier else { return }
                self.finishRequest(throwing: BossWebAPIError.pageLoadTimedOut)
            }
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard self?.requestID == identifier else { return }
                    self?.finishRequest(throwing: error)
                }
            }
        }
        guard let wrapper = try JSONSerialization.jsonObject(with: wrapperData) as? [String: Any],
              wrapper["error"] == nil,
              let status = (wrapper["status"] as? NSNumber)?.intValue,
              let body = wrapper["body"] as? String,
              let bodyData = body.data(using: .utf8) else {
            throw BossWebAPIError.invalidBridgeResponse
        }
        guard (200...299).contains(status) else { throw BossWebAPIError.httpStatus(status) }
        return bodyData
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        prepared = false
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        preparationTimeout?.cancel()
        preparationTimeout = nil
        requestTimeout?.cancel()
        requestTimeout = nil
        let preparation = preparationContinuation
        preparationContinuation = nil
        preparation?.resume(throwing: CancellationError())
        let request = requestContinuation
        requestContinuation = nil
        requestID = nil
        request?.resume(throwing: CancellationError())
        webView.navigationDelegate = nil
        webView = nil
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard !isInvalidated, requestContinuation != nil else { return }
            guard message.name == Self.bridgeName,
                  let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finishRequest(throwing: BossWebAPIError.invalidBridgeResponse)
                return
            }
            guard wrapper["id"] as? String == requestID else { return }
            requestTimeout?.cancel()
            requestTimeout = nil
            let continuation = requestContinuation
            requestContinuation = nil
            requestID = nil
            continuation?.resume(returning: data)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard !isInvalidated else { return }
            prepared = true
            preparationTimeout?.cancel()
            preparationTimeout = nil
            let continuation = preparationContinuation
            preparationContinuation = nil
            continuation?.resume()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finishWithError(error) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { finishWithError(error) }
    }

    private func finishWithError(_ error: Error) {
        guard !isInvalidated else { return }
        prepared = false
        preparationTimeout?.cancel()
        preparationTimeout = nil
        let continuation = preparationContinuation
        preparationContinuation = nil
        invalidate()
        continuation?.resume(throwing: BossWebAPIError.pageLoadFailed(error.localizedDescription))
    }

    private func finishRequest(throwing error: Error) {
        requestTimeout?.cancel()
        requestTimeout = nil
        let continuation = requestContinuation
        requestContinuation = nil
        requestID = nil
        invalidate()
        continuation?.resume(throwing: error)
    }
}
