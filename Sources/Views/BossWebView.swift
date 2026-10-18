import AppKit
import SwiftUI
import WebKit

@MainActor
final class BossBrowserController: ObservableObject {
    @Published private(set) var title = "BOSS 直聘"
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorMessage: String?

    let profileID: UUID
    fileprivate weak var webView: WKWebView?

    init(profileID: UUID) {
        self.profileID = profileID
    }

    fileprivate func attachWithoutPublishing(_ webView: WKWebView) {
        self.webView = webView
    }

    fileprivate func refreshState(from webView: WKWebView) {
        title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "BOSS 直聘"
        currentURL = webView.url
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    fileprivate func beginLoading() {
        isLoading = true
        errorMessage = nil
    }

    fileprivate func fail(_ error: Error) {
        isLoading = false
        errorMessage = "页面加载失败：\(error.localizedDescription)"
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        errorMessage = nil
        webView?.reload()
    }

    func openLogin() {
        load(OfficialBossLinkService.login)
    }

    func openJobs() {
        load(OfficialBossLinkService.jobs)
    }

    func openChat() {
        load(OfficialBossLinkService.chat)
    }

    func clearSession() async throws {
        let dataStore = webView?.configuration.websiteDataStore ?? BossWebSessionService.dataStore(for: profileID)
        try await BossWebSessionService.clear(dataStore: dataStore)
        openLogin()
    }

    private func load(_ url: URL) {
        guard OfficialBossLinkService.isOfficialURL(url) else { return }
        errorMessage = nil
        webView?.load(URLRequest(url: url))
    }
}

struct BossWebView: NSViewRepresentable {
    @ObservedObject var controller: BossBrowserController
    let initialURL: URL
    let isVisuallyHidden: Bool
    let onCookiesChanged: ([HTTPCookie]) -> Void

    init(
        controller: BossBrowserController,
        initialURL: URL,
        isVisuallyHidden: Bool = false,
        onCookiesChanged: @escaping ([HTTPCookie]) -> Void
    ) {
        self.controller = controller
        self.initialURL = initialURL
        self.isVisuallyHidden = isVisuallyHidden
        self.onCookiesChanged = onCookiesChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        makeBrowserContainer(coordinator: context.coordinator)
    }

    func makeBrowserContainer(coordinator: Coordinator) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BossWebSessionService.dataStore(for: controller.profileID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = isVisuallyHidden
        webView.alphaValue = isVisuallyHidden ? 0 : 1
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        configuration.websiteDataStore.httpCookieStore.add(coordinator)
        coordinator.webView = webView
        attachControllerWithoutPublishing(to: webView)
        webView.load(URLRequest(url: initialURL))
        coordinator.checkLoginStatus()
        // 卸载后仅保留空容器，释放 WebKit 对账号数据存储的引用。
        let container = NSView(frame: .zero)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        context.coordinator.parent = self
        webView.isHidden = isVisuallyHidden
        webView.alphaValue = isVisuallyHidden ? 0 : 1
        if controller.webView !== webView {
            attachControllerWithoutPublishing(to: webView)
        }
    }

    /// SwiftUI 渲染期间只绑定视图，状态发布延后到下一次主线程调度，避免更新时再次触发渲染。
    private func attachControllerWithoutPublishing(to webView: WKWebView) {
        controller.attachWithoutPublishing(webView)
        let controller = controller
        Task { @MainActor [weak controller, weak webView] in
            await Task.yield()
            guard let controller,
                  let webView,
                  controller.webView === webView else { return }
            controller.refreshState(from: webView)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let webView = coordinator.webView else { return }
        webView.stopLoading()
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if coordinator.parent.controller.webView === webView {
            coordinator.parent.controller.webView = nil
        }
        webView.removeFromSuperview()
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var parent: BossWebView
        weak var webView: WKWebView?

        init(parent: BossWebView) {
            self.parent = parent
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                parent.controller.beginLoading()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                parent.controller.refreshState(from: webView)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                parent.controller.refreshState(from: webView)
                checkLoginStatus()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                parent.controller.fail(error)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                parent.controller.fail(error)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if OfficialBossLinkService.isOfficialURL(url) || url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, OfficialBossLinkService.isOfficialURL(url) {
                _ = MainActor.assumeIsolated {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor [weak self] in
                self?.checkLoginStatus()
            }
        }

        func checkLoginStatus() {
            guard let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor [weak self] in
                    self?.parent.onCookiesChanged(cookies)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
