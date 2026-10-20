import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossSessions: BossSessionCoordinator

    private var selectedAccount: BossAccount? {
        store.filteredAccounts.first { $0.id == store.selectedAccountID } ?? store.filteredAccounts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "账号管理",
                subtitle: "扫码登录，管理多个账号。",
                systemImage: "person.2"
            ) {
                Button(action: addAccount) {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("添加一个独立的 BOSS 扫码登录会话")
            }
            Divider()

            HSplitView {
                accountList
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)

                Group {
                    if let account = selectedAccount {
                        AccountDetailView(
                            account: account,
                            session: bossSessions.session(for: account)
                        )
                        .id(account.id)
                    } else {
                        AccountOnboardingView(addAccount: addAccount)
                    }
                }
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
    }

    private var accountList: some View {
        let unreadByAccount = store.snapshot.conversations.reduce(into: [UUID: Int]()) {
            $0[$1.accountID, default: 0] += $1.unreadCount
        }
        let now = Date()
        return List(selection: $store.selectedAccountID) {
            Section("BOSS 账号") {
                ForEach(store.filteredAccounts) { account in
                    let quota = store.dailyCommunicationLastSyncedAt(accountID: account.id, now: now) == nil
                        ? "待核对"
                        : "\(store.usedDailyGreetingQuotaToday(accountID: account.id, now: now))/\(store.snapshot.automation.dailyGreetingLimit)"
                    AccountRow(
                        account: account,
                        displayLabel: account.selectionLabel(in: store.snapshot.accounts),
                        unreadCount: unreadByAccount[account.id, default: 0],
                        greetingQuota: quota,
                        isSelected: store.selectedAccountID == account.id,
                        session: bossSessions.session(for: account)
                    )
                        .tag(account.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func addAccount() {
        withAnimation {
            _ = store.addBossAccount()
        }
    }
}

private struct AccountOnboardingView: View {
    let addAccount: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(BossPilotTheme.accent.opacity(0.10))
                        .frame(width: 84, height: 84)
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(BossPilotTheme.accent)
                }
                .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text("扫码登录 BOSS 直聘")
                        .font(.title2.bold())
                    Text("添加账号后扫码登录。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 24) {
                    OnboardingStep(number: "1", title: "添加账号")
                    OnboardingStep(number: "2", title: "App 扫码")
                    OnboardingStep(number: "3", title: "手机确认")
                }

                Button("添加第一个 BOSS 账号", action: addAccount)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("创建独立会话并显示 BOSS 登录二维码")

                Text("各账号独立登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OnboardingStep: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.blue, in: Circle())
            Text(title)
                .font(.callout.weight(.medium))
        }
    }
}

private struct AccountRow: View {
    let account: BossAccount
    let displayLabel: String
    let unreadCount: Int
    let greetingQuota: String
    let isSelected: Bool
    @ObservedObject var session: BossAccountSessionController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rowIcon)
                .foregroundStyle(rowColor)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(displayLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(rowSubtitle)
                        .font(.caption)
                        .foregroundStyle(rowColor)
                        .fixedSize()
                }
                Text("未读 \(unreadCount) · 开聊 \(greetingQuota)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(account.lastSyncAt.map {
                    "同步 \($0.formatted(.dateTime.month().day().hour().minute()))"
                } ?? "尚未同步")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .selectionHighlight(isSelected)
        .accessibilityElement(children: .combine)
    }

    private var rowSubtitle: String {
        if account.status == .deleting { return "待完成删除" }
        if account.manualVerificationChallenge != nil { return "需要本人验证" }
        switch session.phase {
        case .authenticated: return session.automationReady ? "可同步" : "会话准备中"
        case .idle, .restoring: return "正在恢复"
        case .failed: return "恢复失败"
        case .removalFailed: return "删除未完成"
        case .signingOut: return "正在退出"
        case .deleting: return "正在删除"
        case .loginRequired: return "待扫码"
        }
    }

    private var rowIcon: String {
        if account.manualVerificationChallenge != nil { return "person.badge.shield.checkmark" }
        switch session.phase {
        case .authenticated: return session.automationReady ? "checkmark.circle.fill" : "hourglass"
        case .failed, .removalFailed: return "exclamationmark.triangle.fill"
        case .idle, .restoring, .signingOut, .deleting: return "arrow.triangle.2.circlepath"
        case .loginRequired: return "qrcode.viewfinder"
        }
    }

    private var rowColor: Color {
        if account.manualVerificationChallenge != nil { return .orange }
        switch session.phase {
        case .authenticated: return session.automationReady ? .green : .orange
        case .failed, .removalFailed: return .orange
        case .loginRequired: return .blue
        case .idle, .restoring, .signingOut, .deleting: return .secondary
        }
    }
}

private struct AccountDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    @EnvironmentObject private var bossAutomation: BossAutomationController
    @EnvironmentObject private var codex: CodexController
    @Environment(\.openWindow) private var openWindow
    let account: BossAccount
    @ObservedObject var session: BossAccountSessionController
    @State private var showingRename = false
    @State private var accountNameDraft = ""
    @State private var isClearingSession = false
    @State private var hasRequestedProfileSync = false
    @State private var isProfileSyncing = false
    @State private var isManualVerificationRechecking = false

    private var qrLogin: BossQRCodeLoginController { session.qrLogin }
    private var isAuthenticated: Bool { session.phase.isAuthenticated }
    private var accountLabel: String { account.selectionLabel(in: store.snapshot.accounts) }

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            Divider()

            if let challenge = displayedManualVerificationChallenge {
                BossManualVerificationBanner(
                    accountLabel: accountLabel,
                    challenge: challenge,
                    isRechecking: isManualVerificationRechecking,
                    openVerificationPage: {
                        openOfficialPage(challenge.recoveryURL, title: "BOSS 安全验证")
                    },
                    recheck: recheckManualVerification
                )
                .padding(16)
                Divider()
            }

            if session.phase == .deleting {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在安全删除“\(accountLabel)”")
                        .font(.headline)
                    Text("正在停止任务并清理登录信息。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .removalFailed(let message) = session.phase {
                ContentUnavailableView {
                    Label("账号数据尚未删完", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(message)\n账号仍保留，请重试删除。")
                }
            } else if session.phase == .signingOut {
                ProgressView("正在退出“\(accountLabel)”并清理登录会话")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isAuthenticated {
                loggedInWorkspace
            } else if session.phase == .restoring || session.phase == .idle {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在恢复“\(accountLabel)”的登录会话")
                        .font(.headline)
                    Text("正在恢复登录状态。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .failed(let message) = session.phase {
                ContentUnavailableView {
                    Label("账号会话恢复失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新恢复") {
                        Task { await session.restoreIfNeeded() }
                    }
                    Button("重新扫码") { session.restartQRCodeLogin() }
                }
            } else {
                QRCodeLoginPanel(controller: qrLogin)
            }
        }
        .task {
            await session.restoreIfNeeded()
            if session.phase.isAuthenticated {
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: true)
                synchronizeRemoteProfileIfNeeded()
            } else if session.phase == .loginRequired {
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase.isAuthenticated {
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: true)
                synchronizeRemoteProfileIfNeeded()
            } else if phase == .loginRequired {
                store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            }
        }
        .onChange(of: session.automationReady) { _, ready in
            if ready { synchronizeRemoteProfileIfNeeded() }
        }
        .onChange(of: store.snapshot.automation.mode) { _, _ in
            synchronizeRemoteProfileIfNeeded()
        }
        .alert("重命名账号", isPresented: $showingRename) {
            TextField("账号名称", text: $accountNameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { store.renameAccount(id: account.id, name: accountNameDraft) }
                .disabled(accountNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("全局生效，刷新资料不会覆盖。")
        }

    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(sessionStatusColor.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: sessionStatusIcon)
                        .foregroundStyle(sessionStatusColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(accountLabel)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)

                Spacer(minLength: 10)

                StatusPill(title: sessionStatusTitle, systemImage: sessionStatusIcon, color: sessionStatusColor)

                Menu {
                    Button("重命名账号") {
                        accountNameDraft = account.customName ?? account.displayName
                        showingRename = true
                    }
                    .disabled(isClearingSession || account.status == .deleting)
                    Divider()
                    Button("退出账号") { signOut() }
                        .disabled(isClearingSession || (!isAuthenticated && account.loginStatus != .loggedIn))
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("账号操作")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("重命名或退出账号")
            }

            accountHeaderActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var displayedManualVerificationChallenge: BossManualVerificationChallenge? {
        guard account.status != .deleting else { return nil }
        switch session.phase {
        case .signingOut, .deleting, .removalFailed:
            return nil
        case .idle, .restoring, .loginRequired, .authenticated, .failed:
            return account.manualVerificationChallenge
        }
    }

    @ViewBuilder
    private var accountHeaderActions: some View {
        if isAuthenticated {
            HStack(spacing: 8) {
                Spacer()
                Button("BOSS 岗位页") {
                    openOfficialPage(OfficialBossLinkService.jobs, title: "BOSS 岗位页")
                }
                .help("打开该账号的 BOSS 岗位页")
                Button("BOSS 消息页") {
                    openOfficialPage(OfficialBossLinkService.chat, title: "BOSS 消息页")
                }
                .buttonStyle(.borderedProminent)
                .help("打开该账号的 BOSS 消息页")
            }
        } else if canRestartQRCode {
            HStack {
                Spacer()
                Button("刷新登录二维码") { session.restartQRCodeLogin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.phase == .restoring)
                    .help("重新向 BOSS 请求登录二维码")
            }
        }
    }

    private var loggedInWorkspace: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if account.manualVerificationChallenge == nil, !session.automationReady {
                        SessionWarmupView(session: session)
                    }
                    accountOverview(availableWidth: geometry.size.width - 44)
                    remoteProfilePanel

                    accountActivityPanel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        }
    }

    private func accountOverview(availableWidth: CGFloat) -> some View {
        let jobs = store.snapshot.jobs.filter { $0.accountID == account.id }
        let conversations = store.snapshot.conversations.filter { $0.accountID == account.id }
        let now = Date()
        let greetingsSynced = store.dailyCommunicationLastSyncedAt(accountID: account.id, now: now) != nil
        let exchangesSynced = store.dailyResumeExchangeLastSyncedAt(accountID: account.id, now: now) != nil
        let usedGreetings = store.usedDailyGreetingQuotaToday(accountID: account.id, now: now)
        return LazyVGrid(
            columns: MetricCard.columns(for: availableWidth),
            alignment: .leading,
            spacing: 12
        ) {
            MetricCard(title: "推荐岗位", value: "\(jobs.filter { $0.stage == .recommended }.count)",
                       detail: "共 \(jobs.count) 个岗位", systemImage: "briefcase.fill", color: BossPilotTheme.accent)
            MetricCard(title: "未读消息", value: "\(conversations.reduce(0) { $0 + $1.unreadCount })",
                       detail: "\(conversations.count) 个会话", systemImage: "bubble.left.fill", color: BossPilotTheme.accent)
            MetricCard(title: "今日开聊", value: greetingsSynced
                       ? "\(usedGreetings)/\(store.snapshot.automation.dailyGreetingLimit)" : "待核对",
                       detail: greetingsSynced ? "剩余 \(max(0, store.snapshot.automation.dailyGreetingLimit - usedGreetings)) 次" : "等待核对", systemImage: "paperplane.fill", color: .orange)
            MetricCard(title: "今日交换", value: exchangesSynced
                       ? "\(store.resumeExchangeCountToday(accountID: account.id, now: now))" : "待核对",
                       detail: "附件简历", systemImage: "arrow.left.arrow.right", color: .green)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前账号数据概览")
    }

    private var accountActivityPanel: some View {
        let entries = Array(store.snapshot.activity.filter {
            $0.accountID == account.id && $0.title != "BOSS 身份已同步，部分资料暂不可用"
        }
            .sorted { $0.createdAt > $1.createdAt }.prefix(3))
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "最近记录")
            if entries.isEmpty {
                Text("暂无账号动态")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(entry.level == .error ? Color.red : entry.level == .warning ? .orange : BossPilotTheme.accent)
                        .padding(.top, 5)
                    Text(entry.title)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .panelStyle()
    }

    private var remoteProfilePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeading(title: "账号资料")
                if store.snapshot.automation.allowsConnectorReads {
                    Button {
                        hasRequestedProfileSync = false
                        synchronizeRemoteProfileIfNeeded(force: true)
                    } label: {
                        if isProfileSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新资料", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isProfileSyncing || !session.automationReady || account.manualVerificationChallenge != nil)
                    .help(account.manualVerificationChallenge != nil
                        ? "请先完成 BOSS 本人验证"
                        : session.automationReady ? "从 BOSS 重新同步账号资料" : "等待当前账号的同步会话准备完成")
                }
            }

            if let profile = account.remoteProfile {
                LabeledContent("BOSS 姓名", value: profile.name.isEmpty ? accountLabel : profile.name)
                if !profile.currentTitle.isEmpty { LabeledContent("当前职位", value: profile.currentTitle) }
                if !profile.city.isEmpty { LabeledContent("所在城市", value: profile.city) }
                if !profile.workExperience.isEmpty { LabeledContent("工作经验", value: profile.workExperience) }
                if let education = profile.educationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !education.isEmpty {
                    LabeledContent("教育经历", value: education)
                }
                if let work = profile.recentWorkSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !work.isEmpty {
                    LabeledContent("最近工作", value: work)
                }
                if !profile.jobStatus.isEmpty { LabeledContent("求职状态", value: profile.jobStatus) }
                if !profile.expectations.isEmpty {
                    LabeledContent("在线求职期望", value: profile.expectations.joined(separator: "；"))
                }
                if let description = profile.selfDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("个人优势")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(description)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if !store.snapshot.automation.allowsConnectorReads {
                Label("请切换至辅助或自动模式后同步。", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            } else if isProfileSyncing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在同步 BOSS 资料。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(session.automationReady
                    ? "尚未同步到账号资料，可点击“刷新资料”重试。"
                    : "登录会话正在准备，完成后会自动同步 BOSS 账号资料。")
                    .foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("最近同步", value: account.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未同步")
            LabeledContent("最近登录", value: account.lastLoginAt?.formatted(date: .abbreviated, time: .shortened) ?? "暂无记录")
        }
        .panelStyle()
    }

    private func openOfficialPage(_ url: URL, title: String) {
        openWindow(
            value: BossOfficialPageRequest(
                accountID: account.id,
                title: title,
                initialURL: url
            )
        )
    }

    private func synchronizeRemoteProfileIfNeeded(force: Bool = false) {
        guard store.snapshot.automation.allowsConnectorReads,
              account.manualVerificationChallenge == nil,
              session.phase.isAuthenticated,
              session.automationReady,
              !isProfileSyncing else { return }
        if !force {
            guard !hasRequestedProfileSync else { return }
            if session.profileBindingVerified,
               let syncedAt = account.remoteProfile?.syncedAt,
               Date().timeIntervalSince(syncedAt) < 6 * 60 * 60 {
                return
            }
        }
        hasRequestedProfileSync = true
        isProfileSyncing = true
        Task {
            let outcome = await bossAutomation.synchronizeProfile(account: account, session: session, store: store)
            isProfileSyncing = false
            if outcome != .performed { hasRequestedProfileSync = false }
        }
    }

    private func recheckManualVerification() {
        guard account.manualVerificationChallenge != nil,
              !isManualVerificationRechecking else { return }
        isManualVerificationRechecking = true
        Task {
            _ = await bossAutomation.recheckManualVerification(
                account: account,
                session: session,
                store: store
            )
            isManualVerificationRechecking = false
        }
    }

    private func signOut() {
        bossAutomation.invalidateOperations(accountID: account.id)
        codex.cancelOperations(accountID: account.id)
        do {
            try store.beginBossSignOut(accountID: account.id)
        } catch {
            store.report(error)
            return
        }
        isClearingSession = true
        session.beginSignOutBarrier()
        Task { @MainActor in
            defer { isClearingSession = false }
            do {
                await codex.cancelOperationsAndWait(accountID: account.id)
                do {
                    try await bossAutomation.cancelInvalidatedOperationsAndWait(accountID: account.id)
                } catch {
                    store.addActivity(
                        accountID: account.id,
                        level: .warning,
                        title: "后台分析仍在收尾",
                        detail: "网络写入已同步失效，继续清理登录会话；旧分析结果不会再写入。"
                    )
                }
                try await session.signOut()
                store.addActivity(
                    accountID: account.id,
                    level: .info,
                    title: "BOSS 账号已退出",
                    detail: "本地记录已保留。"
                )
            } catch {
                store.report(error)
            }
        }
    }

    private var sessionStatusTitle: String {
        if account.status == .deleting { return "删除中" }
        if account.manualVerificationChallenge != nil { return "需要本人验证" }
        switch session.phase {
        case .authenticated: return session.automationReady ? "可同步" : "已登录 · 准备中"
        case .idle, .restoring: return "正在恢复"
        case .failed: return "恢复失败"
        case .removalFailed: return "删除未完成"
        case .signingOut: return "退出中"
        case .deleting: return "删除中"
        case .loginRequired: return "待扫码"
        }
    }

    private var sessionStatusIcon: String {
        if account.manualVerificationChallenge != nil { return "person.badge.shield.checkmark" }
        switch session.phase {
        case .authenticated: return session.automationReady ? "checkmark.circle.fill" : "hourglass"
        case .idle, .restoring, .signingOut, .deleting: return "arrow.triangle.2.circlepath"
        case .failed, .removalFailed: return "exclamationmark.triangle.fill"
        case .loginRequired: return "qrcode.viewfinder"
        }
    }

    private var sessionStatusColor: Color {
        if account.manualVerificationChallenge != nil { return .orange }
        switch session.phase {
        case .authenticated: return session.automationReady ? .green : .orange
        case .failed, .removalFailed: return .orange
        case .loginRequired: return BossPilotTheme.accent
        case .idle, .restoring, .signingOut, .deleting: return .secondary
        }
    }

    private var sessionSubtitle: String {
        if account.manualVerificationChallenge != nil {
            return "已暂停该账号的 BOSS 请求，等待你在官方页面完成验证"
        }
        switch session.phase {
        case .idle, .restoring: return "正在恢复持久网页登录态"
        case .loginRequired: return "请使用 BOSS 直聘 App 扫码"
        case .authenticated: return session.automationReady ? "登录会话已就绪，可同步 BOSS 数据" : "已登录，正在准备数据同步会话"
        case .signingOut: return "正在安全退出账号"
        case .deleting: return "正在安全删除账号数据"
        case .removalFailed: return "账号数据删除未完成"
        case .failed: return "登录会话恢复失败"
        }
    }

    private var accountSubtitle: String {
        if account.manualVerificationChallenge != nil { return sessionSubtitle }
        guard let summary = account.remoteProfile?.summary, !summary.isEmpty else { return sessionSubtitle }
        return summary
    }

    private var canRestartQRCode: Bool {
        if session.phase == .loginRequired { return true }
        if case .failed = session.phase { return true }
        return false
    }

}

private struct SessionWarmupView: View {
    @ObservedObject var session: BossAccountSessionController

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在准备 BOSS 数据同步")
                    .font(.headline)
                Text("已登录，正在准备同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .panelStyle()
    }
}

private struct QRCodeLoginPanel: View {
    @ObservedObject var controller: BossQRCodeLoginController

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 7) {
                    Text("BOSS 直聘扫码登录")
                        .font(.title.bold())
                    Text("使用 BOSS 直聘 App 扫码并确认。")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    LoginFlowStep(number: 1, title: "扫描二维码", active: controller.stage.activeStep >= 1)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                    LoginFlowStep(number: 2, title: "手机确认", active: controller.stage.activeStep >= 2)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                    LoginFlowStep(number: 3, title: "建立登录会话", active: controller.stage.activeStep >= 3)
                }

                Group {
                    if let image = controller.qrImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 260, height: 260)
                            .padding(18)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.08)))
                            .accessibilityLabel("BOSS 登录二维码")
                            .accessibilityHint("使用 BOSS 直聘 App 扫描")
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.quaternary.opacity(0.45))
                            ProgressView()
                                .controlSize(.large)
                        }
                        .frame(width: 296, height: 296)
                    }
                }

                VStack(spacing: 6) {
                    Label(controller.stage.title, systemImage: statusImage)
                        .font(.headline)
                        .foregroundStyle(statusColor)

                    if controller.stage == .waitingForScan, controller.qrImage == nil {
                        Text("正在获取二维码。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let expiresAt = controller.expiresAt,
                       controller.stage != .expired,
                       controller.stage != .loggedIn {
                        HStack(spacing: 4) {
                            Text("二维码剩余")
                            Text(expiresAt, style: .timer)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if case .failed(let message) = controller.stage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                }

                if controller.stage == .expired || isFailed {
                    Button("刷新二维码") { controller.restart() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("重新向 BOSS 请求登录二维码")
                }

                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                    Text("请使用 BOSS 直聘 App 扫码。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .padding(.horizontal, 24)
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.stage { return true }
        return false
    }

    private var statusImage: String {
        switch controller.stage {
        case .loggedIn: "checkmark.circle.fill"
        case .expired, .failed: "exclamationmark.triangle.fill"
        case .preparing, .establishingSession: "arrow.triangle.2.circlepath"
        default: "qrcode.viewfinder"
        }
    }

    private var statusColor: Color {
        switch controller.stage {
        case .loggedIn: .green
        case .expired, .failed: .orange
        default: .blue
        }
    }
}

private struct LoginFlowStep: View {
    let number: Int
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(active ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(active ? Color.blue : Color.secondary.opacity(0.15), in: Circle())
            Text(title)
                .font(.caption)
                .foregroundStyle(active ? .primary : .secondary)
        }
    }
}
