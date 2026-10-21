import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var codex: CodexController
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    @EnvironmentObject private var bossAutomation: BossAutomationController
    @Environment(\.openWindow) private var openWindow
    @State private var metricsRefreshStart = Date()
    @State private var showAllAttentionActions = false
    @State private var expandedActionIDs: Set<UUID> = []
    @State private var recheckingVerificationAccountIDs: Set<UUID> = []

    let navigate: (SidebarDestination) -> Void

    private var selectedAccounts: [BossAccount] {
        store.filteredAccounts
    }

    private var recommendedJobs: [JobListing] {
        let accountIDs = Set(store.statisticsAccounts.map(\.id))
        return store.jobsInDisplayOrder
            .filter { $0.stage == .recommended && accountIDs.contains($0.accountID) && ($0.id.hasPrefix("boss-") || $0.securityID?.isEmpty == false) }
    }

    private var recentConversations: [Conversation] {
        let accountIDs = Set(store.statisticsAccounts.map(\.id))
        return store.snapshot.conversations
            .filter { accountIDs.contains($0.accountID) && ($0.remoteConversationID != nil || $0.id.hasPrefix("boss-")) }
            .sorted { $0.latestActivityAt > $1.latestActivityAt }
    }

    private var unreadMessages: Int {
        recentConversations.reduce(0) { $0 + $1.unreadCount }
    }

    private var pendingActions: Int {
        attentionActions.count
    }

    private var attentionActions: [PendingAction] {
        let accountIDs = Set(store.statisticsAccounts.map(\.id))
        return store.snapshot.pendingActions
            .filter { accountIDs.contains($0.accountID) && $0.status.requiresAttention }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var resumeDeliveryRecords: [ResumeDeliveryRecord] {
        let accountIDs = Set(store.statisticsAccounts.map(\.id))
        return store.snapshot.resumeDeliveryRecords
            .filter { accountIDs.contains($0.accountID) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var connectedAccounts: [BossAccount] {
        selectedAccounts.filter {
            $0.status == .active &&
                $0.manualVerificationChallenge == nil &&
                bossSessions.existingSession(for: $0.id)?.automationReady == true
        }
    }

    private var challengedAccounts: [BossAccount] {
        selectedAccounts.filter {
            $0.status == .active && $0.manualVerificationChallenge != nil
        }
    }

    private var activeAccounts: [BossAccount] {
        selectedAccounts.filter { $0.status == .active }
    }

    private var authenticatedAccounts: [BossAccount] {
        activeAccounts.filter {
            bossSessions.existingSession(for: $0.id)?.phase.isAuthenticated == true
        }
    }

    private var restoringAccounts: [BossAccount] {
        activeAccounts.filter { account in
            guard account.loginStatus == .loggedIn,
                  account.manualVerificationChallenge == nil else { return false }
            guard let phase = bossSessions.existingSession(for: account.id)?.phase else { return true }
            return phase == .idle || phase == .restoring
        }
    }

    private var preparingAccounts: [BossAccount] {
        authenticatedAccounts.filter {
            $0.manualVerificationChallenge == nil &&
                bossSessions.existingSession(for: $0.id)?.automationReady != true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "总览",
                subtitle: "查看岗位、消息和今日进展。",
                systemImage: "rectangle.grid.2x2"
            )
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if shouldShowSetupPanel {
                        setupPanel
                    }

                    ForEach(challengedAccounts) { account in
                        if let challenge = account.manualVerificationChallenge {
                            BossManualVerificationBanner(
                                accountLabel: account.selectionLabel(in: store.snapshot.accounts),
                                challenge: challenge,
                                isRechecking: recheckingVerificationAccountIDs.contains(account.id),
                                openVerificationPage: {
                                    openVerificationPage(account: account, challenge: challenge)
                                },
                                recheck: { recheckManualVerification(for: account) }
                            )
                        }
                    }

                    if !store.snapshot.accounts.isEmpty {
                        bossDataToolbar
                    }

                    dashboardMetrics

                    if !resumeDeliveryRecords.isEmpty {
                        ResumeDeliveryActivityPanel(
                            title: "附件简历投递",
                            detail: "查看所选账号的简历投递进度。",
                            records: resumeDeliveryRecords,
                            accounts: store.snapshot.accounts,
                            conversations: store.snapshot.conversations,
                            collapsedCount: 4
                        ) { record in
                            store.selectedAccountID = record.accountID
                            store.selectedConversationID = record.conversationID
                            navigate(.conversations)
                        }
                    }

                    if !attentionActions.isEmpty {
                        attentionPanel
                    }

                    if hasWorkspaceData {
                        workspaceDataPanels
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("")
        .onAppear(perform: ensureAccountSelection)
        .onChange(of: store.snapshot.accounts.filter { $0.status != .deleting }.map(\.id)) { _, _ in ensureAccountSelection() }
    }

    private var bossDataToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                syncSummary
                Spacer(minLength: 16)
                syncControls
            }

            if !preparingAccounts.isEmpty {
                HStack(spacing: 8) {
                    Label("\(preparingAccounts.count) 个已登录账号正在准备同步会话", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("查看账号") { navigate(.accounts) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .panelStyle()
    }

    private var syncSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BossPilotTheme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("BOSS 数据同步")
                    .font(.headline)
                Text(syncStatusText)
                    .font(.caption)
                    .foregroundStyle(syncStatusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }

    private var syncControls: some View {
        HStack(spacing: 10) {
            Button {
                synchronizeBossData()
            } label: {
                Label(
                    bossAutomation.isManualSyncRunning ? "正在同步" : "同步 BOSS 数据",
                    systemImage: "arrow.clockwise"
                )
                .frame(minWidth: 112)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(syncButtonDisabled)
            .help(syncStatusText)

        }
    }

    private var dashboardMetrics: some View {
        TimelineView(.periodic(from: metricsRefreshStart, by: 60)) { context in
            let accounts = store.statisticsAccounts
            let communicationsSynced = accounts.allSatisfy { store.dailyCommunicationLastSyncedAt(accountID: $0.id, now: context.date) != nil }
            let exchangesSynced = accounts.allSatisfy { store.dailyResumeExchangeLastSyncedAt(accountID: $0.id, now: context.date) != nil }
            let overview = VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "总览")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DashboardMetric.width, maximum: DashboardMetric.width), spacing: 12)], alignment: .leading, spacing: 12) {
                    DashboardMetric(title: "已登录", value: "\(authenticatedAccounts.count)/\(activeAccounts.count)", systemImage: "person.2.fill", color: BossPilotTheme.accent)
                    DashboardMetric(title: "推荐岗位", value: "\(recommendedJobs.count)", systemImage: "briefcase.fill", color: BossPilotTheme.accent)
                    DashboardMetric(title: "未读消息", value: "\(unreadMessages)", systemImage: "bubble.left.fill", color: BossPilotTheme.accent)
                    DashboardMetric(title: "需要你确认", value: "\(pendingActions)", systemImage: "exclamationmark.bubble.fill", color: .orange)
                }
            }
            let today = VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "今日统计")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DashboardMetric.width, maximum: DashboardMetric.width), spacing: 12)], alignment: .leading, spacing: 12) {
                    DashboardMetric(
                        title: "开聊额度",
                        value: accounts.isEmpty ? "0/0" : communicationsSynced
                            ? "\(accounts.reduce(0) { $0 + store.usedDailyGreetingQuotaToday(accountID: $1.id, now: context.date) })/\(accounts.count * store.snapshot.automation.dailyGreetingLimit)" : "待核对",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        color: BossPilotTheme.accent
                    )
                    DashboardMetric(
                        title: "已交换",
                        value: accounts.isEmpty ? "0" : exchangesSynced
                            ? "\(accounts.reduce(0) { $0 + store.resumeExchangeCountToday(accountID: $1.id, now: context.date) })" : "待核对",
                        systemImage: "arrow.left.arrow.right.circle.fill",
                        color: .green
                    )
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    overview.frame(width: 4 * DashboardMetric.width + 3 * 12)
                    today.frame(width: 2 * DashboardMetric.width + 12)
                }
                VStack(alignment: .leading, spacing: 18) {
                    overview
                    today
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attentionPanel: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("需要你确认")
                        .font(.title3.bold())
                    Text("待你处理的事项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if attentionActions.count > 3 {
                    Button(showAllAttentionActions ? "收起" : "查看全部 \(attentionActions.count) 项") {
                        withAnimation { showAllAttentionActions.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else {
                    Text("\(attentionActions.count) 项")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.bottom, 12)

            Divider()

            ForEach(Array(displayedAttentionActions.enumerated()), id: \.element.id) { index, action in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: action.kind == .sendResume ? "doc.badge.arrow.up" : "bubble.left.and.exclamationmark.bubble.right")
                            .foregroundStyle(.orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attentionTitle(for: action))
                                .font(.callout.weight(.semibold))
                            Text(action.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(expandedActionIDs.contains(action.id) ? nil : 2)
                            Text(accountName(for: action.accountID))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(BossPilotTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(BossPilotTheme.accent.opacity(0.09), in: Capsule())
                        }
                        Spacer()
                        if !action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(expandedActionIDs.contains(action.id) ? "收起内容" : "查看内容") {
                                withAnimation {
                                    if !expandedActionIDs.insert(action.id).inserted {
                                        expandedActionIDs.remove(action.id)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("打开对应页面") { openAttention(action) }
                            .buttonStyle(.bordered)
                        Button("标记完成") { store.setActionStatus(id: action.id, status: .completed) }
                            .buttonStyle(.bordered)
                        Button("忽略") { store.setActionStatus(id: action.id, status: .dismissed) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }

                    if expandedActionIDs.contains(action.id),
                       !action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(action.content)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
                            Button {
                                copyActionContent(action)
                            } label: {
                                Label(action.status == .copied ? "已复制" : "复制内容", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.leading, 34)
                    }
                }
                .padding(.vertical, 10)
                if index < displayedAttentionActions.count - 1 { Divider() }
            }
        }
        .panelStyle()
    }

    private var recommendedJobsPanel: some View {
        let jobs = Array(recommendedJobs.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            panelHeader(title: "推荐岗位", detail: "查看全部") { navigate(.jobs) }
            Divider()

            VStack(spacing: 0) {
                ForEach(jobs) { job in
                    Button {
                        store.selectedAccountID = job.accountID
                        store.selectedJobID = job.id
                        navigate(.jobs)
                    } label: {
                        DashboardJobRow(job: job)
                    }
                    .buttonStyle(.plain)
                    if job.id != jobs.last?.id { Divider() }
                }
            }
        }
        .panelStyle()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentMessagesPanel: some View {
        let conversations = Array(recentConversations.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            panelHeader(title: "最新消息", detail: "查看全部") { navigate(.conversations) }
            Divider()

            VStack(spacing: 0) {
                ForEach(conversations) { conversation in
                    Button {
                        store.selectedAccountID = conversation.accountID
                        store.selectedConversationID = conversation.id
                        navigate(.conversations)
                    } label: {
                        DashboardConversationRow(
                            conversation: conversation,
                            accountName: accountName(for: conversation.accountID),
                            salary: conversationSalary(for: conversation),
                            location: conversationLocation(for: conversation)
                        )
                    }
                    .buttonStyle(.plain)
                    if conversation.id != conversations.last?.id { Divider() }
                }
            }
        }
        .panelStyle()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func conversationSalary(for conversation: Conversation) -> String {
        if let salary = conversation.jobSalary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !salary.isEmpty {
            return salary
        }
        return matchingJob(for: conversation)?.salary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func conversationLocation(for conversation: Conversation) -> String {
        if let location = conversation.jobLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            return BossCityResolver.displayText(for: location)
        }
        return matchingJob(for: conversation)?.displayLocation ?? ""
    }

    private func matchingJob(for conversation: Conversation) -> JobListing? {
        let normalizedTitle = dashboardNormalizedText(conversation.jobTitle)
        let normalizedCompany = dashboardNormalizedText(conversation.company)
        guard !normalizedTitle.isEmpty else { return nil }
        return store.snapshot.jobs.first { job in
            guard job.accountID == conversation.accountID,
                  dashboardNormalizedText(job.title) == normalizedTitle else { return false }
            return normalizedCompany.isEmpty || dashboardNormalizedText(job.company) == normalizedCompany
        }
    }

    private func dashboardNormalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(setupTitle)
                    .font(.title3.bold())
                Text(setupDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()

            if challengedAccounts.isEmpty {
                if authenticatedAccounts.isEmpty {
                    if restoringAccounts.isEmpty {
                        SetupActionRow(
                            title: activeAccounts.isEmpty ? "添加账号并扫码" : "扫码登录 BOSS",
                            detail: "每个账号使用独立网页会话",
                            systemImage: "qrcode.viewfinder"
                        ) { navigate(.accounts) }
                    } else {
                        SetupActionRow(
                            title: "正在恢复登录会话",
                            detail: "无需重新扫码，恢复完成后会自动继续",
                            systemImage: "arrow.triangle.2.circlepath"
                        ) { navigate(.accounts) }
                    }
                } else if connectedAccounts.isEmpty {
                    SetupActionRow(
                        title: "查看会话准备状态",
                        detail: "已登录，正在补齐岗位和消息同步所需的网页会话",
                        systemImage: "hourglass"
                    ) { navigate(.accounts) }
                }
            }
            if !store.snapshot.resume.hasStoredAttachment {
                setupRow(title: "添加附件简历", detail: "保留原文件并自动提取简历画像", systemImage: "doc.text")
            }
            if !store.snapshot.preferences.hasSearchCriteria {
                setupRow(title: "写下求职要求", detail: "用一段自然语言说明方向、地点、薪资和排除项", systemImage: "text.alignleft")
            }
            if store.snapshot.automation.mode == .automatic, !hasAutomaticTask {
                automationRow(title: "开启自动任务", detail: "至少启用岗位检索或消息监控", systemImage: "bolt")
            }
        }
        .panelStyle()
        .frame(maxWidth: 860, alignment: .topLeading)
    }

    @ViewBuilder
    private var workspaceDataPanels: some View {
        if !recommendedJobs.isEmpty, !recentConversations.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                recommendedJobsPanel
                recentMessagesPanel
            }
        } else if !recommendedJobs.isEmpty {
            recommendedJobsPanel
        } else if !recentConversations.isEmpty {
            recentMessagesPanel
        }
    }

    private var setupTitle: String {
        if !challengedAccounts.isEmpty { return "补全求职设置" }
        if !restoringAccounts.isEmpty, authenticatedAccounts.isEmpty { return "正在恢复 BOSS 登录" }
        if authenticatedAccounts.isEmpty { return activeAccounts.isEmpty ? "开始使用 BossPilot" : "登录 BOSS 账号" }
        if connectedAccounts.isEmpty { return "BOSS 会话正在准备" }
        return "补全要求"
    }

    private var setupDetail: String {
        if !challengedAccounts.isEmpty { return "验证操作请在下方提醒中处理，这里只保留尚未完成的求职设置。" }
        if !restoringAccounts.isEmpty, authenticatedAccounts.isEmpty { return "已保存的独立网页会话正在恢复，不会要求重复扫码。" }
        if authenticatedAccounts.isEmpty { return "扫码登录后，岗位、账号资料和最近沟通都从 BOSS 同步。" }
        if connectedAccounts.isEmpty { return "登录没有丢失；准备完成后即可同步 BOSS 数据。" }
        return "添加附件简历并填写岗位检索要求后，即可开始匹配。"
    }

    private func panelHeader(title: String, detail: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            if let detail {
                Button(detail, action: action).buttonStyle(.link).font(.caption)
            }
        }
        .padding(.bottom, 12)
    }

    private func automationRow(title: String, detail: String, systemImage: String) -> some View {
        Button { navigate(.automation) } label: {
            SetupActionRowLabel(title: title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func setupRow(title: String, detail: String, systemImage: String) -> some View {
        Button { navigate(.setup) } label: {
            SetupActionRowLabel(title: title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private var hasAutomaticTask: Bool {
        store.snapshot.automation.automaticallySearchJobs || store.snapshot.automation.automaticallyMonitorMessages
    }

    private var displayedAttentionActions: [PendingAction] {
        showAllAttentionActions ? attentionActions : Array(attentionActions.prefix(3))
    }

    private var hasWorkspaceData: Bool {
        !recommendedJobs.isEmpty ||
            !recentConversations.isEmpty ||
            pendingActions > 0 ||
            !resumeDeliveryRecords.isEmpty
    }

    private var shouldShowSetupPanel: Bool {
        let needsJobSetup = !store.snapshot.resume.hasStoredAttachment ||
            !store.snapshot.preferences.hasSearchCriteria ||
            (store.snapshot.automation.mode == .automatic && !hasAutomaticTask)
        let needsAccountSetup = challengedAccounts.isEmpty &&
            (authenticatedAccounts.isEmpty || connectedAccounts.isEmpty)
        return needsJobSetup || needsAccountSetup
    }

    private var syncButtonDisabled: Bool {
        bossAutomation.isManualSyncRunning || !store.snapshot.automation.allowsConnectorReads || connectedAccounts.isEmpty
    }

    private var syncStatusText: String {
        if bossAutomation.isManualSyncRunning { return "正在同步账号资料、岗位和最近沟通摘要" }
        if let accountID = selectedAccounts.first?.id,
           let account = challengedAccounts.first(where: { $0.id == accountID }),
           let challenge = account.manualVerificationChallenge {
            return challenge.userFacingReason
        }
        if let accountID = selectedAccounts.first?.id, let status = bossAutomation.statusByAccount[accountID] { return status }
        if authenticatedAccounts.isEmpty { return "尚无已登录账号，请先扫码登录" }
        if connectedAccounts.isEmpty, !challengedAccounts.isEmpty { return "账号等待你完成 BOSS 本人验证" }
        if connectedAccounts.isEmpty { return "账号已登录，接口会话正在准备" }
        if let date = bossAutomation.lastCycleAt {
            return "已连接 \(connectedAccounts.count) 个账号 · 上次同步 \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "已连接 \(connectedAccounts.count) 个账号，可同步岗位和消息"
    }

    private var syncStatusColor: Color {
        connectedAccounts.isEmpty || !store.snapshot.automation.allowsConnectorReads
            ? .orange
            : .secondary
    }

    private func ensureAccountSelection() {
        if !store.snapshot.accounts.contains(where: { $0.id == store.selectedAccountID && $0.status != .deleting }) {
            store.selectedAccountID = store.snapshot.accounts.first { $0.status == .active }?.id
                ?? store.snapshot.accounts.first { $0.status != .deleting }?.id
        }
    }

    private func synchronizeBossData() {
        let accounts = connectedAccounts
        Task {
            for account in accounts {
                await bossAutomation.synchronizeNow(accountID: account.id, using: store, sessions: bossSessions, codex: codex)
            }
        }
    }

    private func openVerificationPage(account: BossAccount, challenge: BossManualVerificationChallenge) {
        openWindow(
            value: BossOfficialPageRequest(
                accountID: account.id,
                title: "BOSS 安全验证",
                initialURL: challenge.recoveryURL
            )
        )
    }

    private func recheckManualVerification(for account: BossAccount) {
        guard account.manualVerificationChallenge != nil,
              recheckingVerificationAccountIDs.insert(account.id).inserted else { return }
        let session = bossSessions.session(for: account)
        Task {
            await session.restoreIfNeeded()
            _ = await bossAutomation.recheckManualVerification(
                account: account,
                session: session,
                store: store
            )
            recheckingVerificationAccountIDs.remove(account.id)
        }
    }

    private func accountName(for accountID: UUID) -> String {
        store.snapshot.accounts.first(where: { $0.id == accountID })?
            .selectionLabel(in: store.snapshot.accounts) ?? "未知账号"
    }

    private func attentionTitle(for action: PendingAction) -> String {
        switch action.kind {
        case .sendResume: "招聘方可能接受简历"
        case .sendGreeting: "开聊动作需要确认"
        case .sendMessage: "回复内容需要确认"
        }
    }

    private func openAttention(_ action: PendingAction) {
        store.selectedAccountID = action.accountID
        if let conversationID = action.conversationID {
            store.selectedConversationID = conversationID
            navigate(.conversations)
        } else if let jobID = action.jobID {
            store.selectedJobID = jobID
            navigate(.jobs)
        } else {
            navigate(.dashboard)
        }
    }

    private func copyActionContent(_ action: PendingAction) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(action.content, forType: .string)
        store.setActionStatus(id: action.id, status: .copied)
    }

}

private struct DashboardMetric: View {
    static let width: CGFloat = 160

    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: Self.width, height: 64, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius).stroke(Color.secondary.opacity(0.14)))
    }
}

private struct DashboardJobRow: View {
    let job: JobListing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(job.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if !job.salary.isEmpty {
                        Text(job.salary).font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                Text([job.company, job.displayLocation, job.recruiterDisplayLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let score = job.assessment?.score {
                Text("\(score)分").font(.caption.bold()).foregroundStyle(score >= 75 ? .green : .orange)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 11)
    }
}

private struct DashboardConversationRow: View {
    let conversation: Conversation
    let accountName: String
    let salary: String
    let location: String

    private var metadataText: String {
        "单位：\(displayValue(conversation.company, fallback: "未标注")) · 薪资：\(displayValue(salary, fallback: "未标注")) · 地域：\(displayValue(location, fallback: "未标注"))"
    }

    private var messageDateText: String {
        conversation.latestActivityAt.formatted(date: .numeric, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(conversation.recruiterName.isEmpty ? "招聘方" : conversation.recruiterName).font(.callout.weight(.semibold))
                    Text(accountName).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(messageDateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(metadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(latestMessageText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.purple, in: Capsule())
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var latestMessageText: String {
        let text = conversation.latestMessage?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "暂无可展示消息" : text
    }

    private func displayValue(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private struct SetupActionRowLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage).foregroundStyle(BossPilotTheme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct SetupActionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SetupActionRowLabel(title: title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}
