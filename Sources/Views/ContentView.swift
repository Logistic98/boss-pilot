import AppKit
import OSLog
import SwiftUI

private let sidebarLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.bosspilot.desktop",
    category: "Sidebar"
)

enum SidebarDestination: String, CaseIterable, Identifiable {
    case dashboard
    case setup
    case automation
    case accounts
    case jobs
    case conversations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "总览"
        case .setup: "求职偏好"
        case .automation: "系统设置"
        case .accounts: "账号管理"
        case .jobs: "岗位列表"
        case .conversations: "沟通会话"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .setup: "wand.and.stars"
        case .automation: "bolt.horizontal.circle"
        case .accounts: "person.2"
        case .jobs: "briefcase"
        case .conversations: "bubble.left.and.bubble.right"
        }
    }
}

enum ContentIssueRoute: Equatable {
    case sidebar(SidebarDestination)
    case configuration(section: String)

    static func resolve(message: String) -> ContentIssueRoute? {
        if message.contains("隐私") || message.contains("智能引擎") || message.contains("智能分析") ||
            message.localizedCaseInsensitiveContains("Codex") {
            return .configuration(section: "codex")
        }
        if message.localizedCaseInsensitiveContains("BOSS") ||
            message.contains("登录") ||
            message.contains("会话") ||
            message.contains("安全验证") ||
            message.contains("异常访问") {
            return .sidebar(.accounts)
        }
        if message.contains("简历") || message.contains("求职要求") {
            return .sidebar(.setup)
        }
        if message.contains("自动") || message.contains("提醒") {
            return .sidebar(.automation)
        }
        return nil
    }
}

struct ContentView: View {
    let launchMode: BossPilotLaunchMode
    let registerMainWindowOpener: (@escaping () -> Void) -> Void
    let registerSettingsOpener: (@escaping () -> Void) -> Void
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var codex: CodexController
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    @EnvironmentObject private var bossAutomation: BossAutomationController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("sidebarSelection") private var selectedRawValue = SidebarDestination.dashboard.rawValue

    private var selectedDestination: SidebarDestination {
        return SidebarDestination(rawValue: selectedRawValue) ?? .dashboard
    }

    private var selection: Binding<SidebarDestination?> {
        Binding(
            get: { selectedDestination },
            set: { destination in
                navigate(to: destination ?? .dashboard)
            }
        )
    }

    private var recommendedJobs: Int {
        let accounts = Set(store.statisticsAccounts.map(\.id))
        return store.snapshot.jobs.lazy.filter { $0.stage == .recommended && accounts.contains($0.accountID) }.count
    }

    private var attentionMessages: Int {
        let accounts = Set(store.statisticsAccounts.map(\.id))
        return Set(
            store.snapshot.pendingActions
                .filter { $0.status.requiresAttention && accounts.contains($0.accountID) }
                .compactMap { action in
                    action.conversationID.map { "\(action.accountID.uuidString)|\($0)" }
                }
        ).count
    }

    private var accountCount: Int {
        store.snapshot.accounts.filter { $0.status != .deleting }.count
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                sidebarBrand

                List(selection: selection) {
                    sidebarGroup("概览")
                    sidebarRow(.dashboard)

                    sidebarGroup("求职")
                    sidebarRow(.setup)
                    sidebarRow(.jobs, badge: recommendedJobs)
                    sidebarRow(.conversations, badge: attentionMessages)

                    sidebarGroup("管理")
                    sidebarRow(.automation)
                    sidebarRow(.accounts, badge: accountCount)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 205, idealWidth: 225, maxWidth: 260)

            VStack(spacing: 0) {
                if let message = store.lastError {
                    AppIssueBanner(
                        message: message,
                        actionTitle: issueRoute == nil ? nil : "去处理",
                        onAction: issueRoute.map { route in
                            { handleIssueRoute(route) }
                        },
                        onDismiss: { store.lastError = nil }
                    )
                }

                GeometryReader { proxy in
                    Group {
                        switch selectedDestination {
                        case .dashboard: DashboardView(navigate: navigate)
                        case .setup: JobSetupView(attachmentStorageDirectory: launchMode.previewRuntime?.stateURL.deletingLastPathComponent().appendingPathComponent("Attachments"))
                        case .automation: SystemSettingsView()
                        case .accounts: AccountsView()
                        case .jobs: JobsView(navigate: navigate)
                        case .conversations: ConversationsView(navigate: navigate)
                        }
                    }
                    .id(selectedDestination)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("全选") { store.accountFilterIDs = nil }
                        Button("取消全选") { store.accountFilterIDs = [] }
                        Divider()
                        ForEach(store.snapshot.accounts.filter { $0.status != .deleting }) { account in
                            Toggle(account.selectionLabel(in: store.snapshot.accounts), isOn: Binding(
                                get: { store.includesAccount(account.id) },
                                set: { _ in store.toggleAccountFilter(account.id) }
                            ))
                        }
                    } label: {
                        Label(store.accountFilterIDs == nil ? "全部账号" : "已选 \(store.filteredAccounts.count) 个账号", systemImage: "person.2")
                    }
                    .accessibilityLabel("全局账号选择")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(BossPilotTheme.accent)
        .background {
            RequirementsWindowGuard(store: store)
            if launchMode.performsLiveRuntimeWork {
                BossSessionLifecycleHost()
            }
        }
        .onAppear {
            registerMainWindowOpener { [openWindow] in
                openWindow(id: BossPilotSceneID.main)
            }
            registerSettingsOpener { showSystemSettings() }
        }
        .task {
            store.load()
            guard launchMode.performsLiveRuntimeWork else {
                return
            }
            bossSessions.bindAuthenticationInvalidation { [weak store] accountID in
                store?.synchronizeBossLoginStatus(accountID: accountID, loggedIn: false)
            }
            bossSessions.bindIdentityRevisionChange { [weak bossAutomation] accountID in
                bossAutomation?.invalidateOperations(accountID: accountID)
            }
            if store.snapshot.accounts.isEmpty {
                navigate(to: .accounts)
            }
            for account in store.snapshot.accounts {
                let session = bossSessions.session(for: account)
                await session.restoreIfNeeded()
                if session.phase.isAuthenticated {
                    store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: true)
                } else if session.phase == .loginRequired {
                    store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
                }
            }
            bossAutomation.synchronize(using: store, sessions: bossSessions, codex: codex)
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue != .active { store.scheduleSave() }
        }
        .onChange(of: selectedRawValue) { _, newValue in
            sidebarLogger.info("Selected page: \(newValue, privacy: .public)")
        }
    }

    private var issueRoute: ContentIssueRoute? {
        guard let message = store.lastError else { return nil }
        return ContentIssueRoute.resolve(message: message)
    }

    private func navigate(to destination: SidebarDestination) {
        guard destination != selectedDestination else { return }
        Task { @MainActor in
            guard await UnsavedRequirementsGuard.confirm(using: store) else { return }
            selectedRawValue = destination.rawValue
        }
    }

    private func handleIssueRoute(_ route: ContentIssueRoute) {
        switch route {
        case let .sidebar(destination):
            navigate(to: destination)
        case let .configuration(section):
            showSystemSettings(section: section)
        }
    }

    private func showSystemSettings(section: String? = nil) {
        Task { @MainActor in
            guard await UnsavedRequirementsGuard.confirm(using: store) else { return }
            if let section {
                UserDefaults.standard.set(section, forKey: "configurationSelection")
            }
            selectedRawValue = SidebarDestination.automation.rawValue
        }
    }

    private func sidebarGroup(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
            .disabled(true)
    }

    @ViewBuilder
    private func sidebarRow(_ destination: SidebarDestination, badge: Int = 0) -> some View {
        HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
                .frame(width: 18)
                .foregroundStyle(selectedRawValue == destination.rawValue ? BossPilotTheme.accent : .secondary)
            Text(destination.title)
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selectedRawValue == destination.rawValue ? BossPilotTheme.accent : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .foregroundStyle(.primary)
        .selectionHighlight(selectedRawValue == destination.rawValue)
        .tag(destination)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge > 0 ? "\(destination.title)，\(badge)" : destination.title)
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
            Text("BossPilot")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

}
