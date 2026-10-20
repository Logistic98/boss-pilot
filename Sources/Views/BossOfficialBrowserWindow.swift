import AppKit
import SwiftUI

struct BossOfficialPageRequest: Codable, Hashable {
    let accountID: UUID
    let title: String
    let initialURL: URL

    init(accountID: UUID, title: String, initialURL: URL) {
        self.accountID = accountID
        self.title = title
        self.initialURL = OfficialBossLinkService.isOfficialURL(initialURL)
            ? initialURL
            : OfficialBossLinkService.home
    }
}

struct BossOfficialBrowserWindow: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    let request: BossOfficialPageRequest

    private var account: BossAccount? {
        store.snapshot.accounts.first { $0.id == request.accountID }
    }

    var body: some View {
        Group {
            if let account {
                BossOfficialBrowserContent(
                    account: account,
                    session: bossSessions.session(for: account),
                    title: request.title,
                    initialURL: request.initialURL
                )
            } else {
                ContentUnavailableView(
                    "账号已不存在",
                    systemImage: "person.crop.circle.badge.xmark",
                    description: Text("账号已删除，请关闭此窗口。")
                )
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(BossWindowActivationView())
    }
}

/// 仅在 SwiftUI 挂载官方页面窗口后启用 AppKit 行为。
private struct BossWindowActivationView: NSViewRepresentable {
    func makeNSView(context: Context) -> BossWindowActivationNSView {
        BossWindowActivationNSView()
    }

    func updateNSView(_ nsView: BossWindowActivationNSView, context: Context) {}
}

private final class BossWindowActivationNSView: NSView {
    private var activatedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, activatedWindow !== window else { return }
        activatedWindow = window
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct BossOfficialBrowserContent: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossAutomation: BossAutomationController
    let account: BossAccount
    @ObservedObject var session: BossAccountSessionController
    let title: String
    let initialURL: URL
    @StateObject private var browser: BossBrowserController

    private var accountLabel: String {
        account.selectionLabel(in: store.snapshot.accounts)
    }

    init(
        account: BossAccount,
        session: BossAccountSessionController,
        title: String,
        initialURL: URL
    ) {
        self.account = account
        self.session = session
        self.title = title
        self.initialURL = OfficialBossLinkService.isOfficialURL(initialURL)
            ? initialURL
            : OfficialBossLinkService.home
        _browser = StateObject(wrappedValue: BossBrowserController(profileID: account.webProfileID))
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()
            if verificationRequired {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.badge.shield.checkmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("需要你完成 BOSS 安全验证")
                            .font(.callout.weight(.semibold))
                        Text(account.manualVerificationChallenge?.recoveryInstruction
                            ?? "请在下方 BOSS 页面完成本人验证。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.10))
                .overlay(alignment: .bottom) { Divider() }
            }
            if let errorMessage = browser.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试") { browser.reload() }
                        .help("重新加载当前 BOSS 页面")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.orange.opacity(0.08))
                .overlay(alignment: .bottom) { Divider() }
            }
            browserBody
        }
        .navigationTitle("\(title) · \(accountLabel)")
        .task {
            await session.restoreIfNeeded()
            if session.phase.isAuthenticated {
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: true)
            } else if session.phase == .loginRequired {
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            }
        }
        .onChange(of: browser.currentURL) { _, url in
            bossAutomation.registerManualVerificationPage(
                account: account,
                url: url,
                store: store
            )
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("后退")

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("前进")

            Button { browser.reload() } label: {
                if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("页面正在加载")
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("刷新")

            HStack(spacing: 7) {
                Image(systemName: verificationRequired ? "exclamationmark.shield.fill" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(verificationRequired ? .orange : .green)
                Text(browser.currentURL?.host ?? "www.zhipin.com")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(browserLocationLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(verificationRequired ? "BOSS 安全验证页" : browserLocationLabel)
            .help(browser.currentURL?.absoluteString ?? title)

            Label(accountLabel, systemImage: "person.crop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .help("当前页面使用的 BOSS 账号")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var verificationRequired: Bool {
        if account.manualVerificationChallenge != nil { return true }
        return BossManualVerificationPagePolicy.evidence(from: browser.currentURL) != nil
    }

    private var browserLocationLabel: String {
        guard let url = browser.currentURL else { return title }
        if verificationRequired { return "安全验证" }
        if url.path.localizedCaseInsensitiveContains("chat") { return "BOSS 消息页" }
        if url.path.localizedCaseInsensitiveContains("job") { return "BOSS 岗位页" }
        return browser.title.isEmpty ? title : browser.title
    }

    @ViewBuilder
    private var browserBody: some View {
        if session.phase.isAuthenticated {
            BossWebView(controller: browser, initialURL: initialURL) { cookies in
                session.observeWebCookies(cookies)
            }
        } else if session.phase == .restoring || session.phase == .idle {
            ProgressView("正在恢复“\(accountLabel)”的登录会话")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let message) = session.phase {
            ContentUnavailableView {
                Label("会话恢复失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(message)\n请回到主窗口的“账号管理”页重试恢复。")
            }
        } else if session.phase == .deleting || session.phase == .signingOut {
            ContentUnavailableView(
                "账号会话正在清理",
                systemImage: "hourglass",
                description: Text("请等待当前账号操作完成后再打开官方页面。")
            )
        } else if case .removalFailed = session.phase {
            ContentUnavailableView(
                "账号删除尚未完成",
                systemImage: "exclamationmark.triangle",
                description: Text("请回到主窗口的“账号管理”页重新执行删除。")
            )
        } else {
            ContentUnavailableView(
                "需要重新登录",
                systemImage: "qrcode.viewfinder",
                description: Text("请先在主窗口的“账号管理”页完成扫码登录。")
            )
        }
    }
}
