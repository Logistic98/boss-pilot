import SwiftUI

struct AutomationSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    @EnvironmentObject private var bossAutomation: BossAutomationController
    @EnvironmentObject private var codex: CodexController
    @Environment(\.openWindow) private var openWindow
    @State private var recheckingVerificationAccountIDs: Set<UUID> = []

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    runCard

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

                    automationCards(width: geometry.size.width)
                }
                .frame(maxWidth: 1140, alignment: .topLeading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .onAppear {
            reconcileAutomaticResumeEligibility()
        }
        .onChange(of: store.snapshot.automation.automaticallyMonitorMessages) { _, _ in
            reconcileAutomaticResumeEligibility()
        }
    }

    private func automationCards(width: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: width >= 900 ? 2 : 1),
            alignment: .leading,
            spacing: 16
        ) {
            automaticSearchCard
            automaticGreetingCard
            messageHandlingCard
            resumeDeliveryCard
        }
    }

    private var runCard: some View {
        return AutomationCard(
            title: "自动运行",
            systemImage: "play.circle"
        ) {
            HStack(spacing: 12) {
                Label(automationStatusTitle, systemImage: automationStatusIcon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(automationStatusColor)
                Spacer()
                if store.snapshot.automation.mode == .automatic {
                    if bossAutomation.isWorkerRunning {
                        Button("停止自动运行") { bossAutomation.stopWorker(using: store) }
                            .help("停止后不再自动检索岗位或同步消息")
                    } else {
                        Button {
                            bossAutomation.startWorker(using: store, sessions: bossSessions, codex: codex)
                        } label: {
                            if bossAutomation.isCycleRunning {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text("本次同步中")
                                }
                            } else {
                                Label("启动自动运行", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStartAutomaticWorker || bossAutomation.isCycleRunning)
                        .help(canStartAutomaticWorker ? "按当前配置启动后台任务" : readinessMessage)
                    }
                }
            }

            if store.snapshot.automation.mode == .automatic {
                configuredActionsSummary
            }

            if store.snapshot.automation.mode == .automatic, let runHint {
                Label(runHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(runHintColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configuredActionsSummary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
            automationCapability("岗位检索", enabled: store.snapshot.automation.automaticallySearchJobs)
            automationCapability("自动开聊", enabled: store.snapshot.automation.automaticallySendGreetings)
            automationCapability("消息同步", enabled: store.snapshot.automation.automaticallyMonitorMessages)
            automationCapability("简历投递", enabled: store.snapshot.automation.automaticallyMonitorMessages && store.snapshot.automation.automaticallySendResume)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("自动任务摘要")
    }

    private func automationCapability(_ title: String, enabled: Bool) -> some View {
        Label {
            Text(title)
                .font(.caption)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
        } icon: {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        }
        .accessibilityLabel("\(title)，\(enabled ? "已开启" : "未开启")")
    }

    private var automaticSearchCard: some View {
        AutomationCard(title: "岗位检索", systemImage: "magnifyingglass") {
            Label("自动检索已开启", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Stepper("检索周期：每 \(store.snapshot.automation.searchIntervalMinutes) 分钟",
                    value: intBinding(\.searchIntervalMinutes), in: AutomationSettings.searchIntervalMinutesRange, step: 5)
            Toggle("同步后自动评估", isOn: boolBinding(\.automaticallyAssessJobs))
        }
    }

    private var automaticGreetingCard: some View {
        AutomationCard(title: "开聊节奏", systemImage: "paperplane") {
            Label("匹配通过后自动开聊", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Stepper("每个账号每日最多 \(store.snapshot.automation.dailyGreetingLimit) 次",
                    value: intBinding(\.dailyGreetingLimit), in: AutomationSettings.dailyGreetingLimitRange, step: 5)
            Stepper("开聊间隔：至少 \((Double(store.snapshot.automation.greetingIntervalSeconds) / 60).formatted(.number.precision(.fractionLength(0...1)))) 分钟",
                    value: intBinding(\.greetingIntervalSeconds), in: AutomationSettings.greetingIntervalSecondsRange, step: 60)
        }
    }

    private var messageHandlingCard: some View {
        AutomationCard(title: "消息处理", systemImage: "bubble.left.and.bubble.right") {
            Toggle("自动同步消息", isOn: automaticTaskBinding(\.automaticallyMonitorMessages))
            Stepper("消息周期：每 \(store.snapshot.automation.monitorIntervalMinutes) 分钟",
                    value: intBinding(\.monitorIntervalMinutes), in: AutomationSettings.monitorIntervalMinutesRange, step: 15)
                .disabled(!store.snapshot.automation.automaticallyMonitorMessages)
            Toggle("生成待办", isOn: boolBinding(\.automaticallyDraftReplies))
                .help("过滤明确拒绝，将问题和面试邀请加入待办")
        }
    }

    private var resumeDeliveryCard: some View {
        AutomationCard(title: "简历投递", systemImage: "doc.badge.arrow.up") {
            Toggle("对方同意后自动投递", isOn: automaticResumeBinding)
                .disabled(!canEnableAutomaticResume)
                .help(automaticResumeUnavailableReason ?? "仅使用完整消息中的明确同意或 BOSS 索要简历卡片")
            ResumeAttachmentButton()
            LabeledContent("投递调度", value: "后续 3 分钟 · 回读 5 分钟")
            if let automaticResumeUnavailableReason {
                Text(automaticResumeUnavailableReason).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var runHint: String? {
        guard store.snapshot.automation.mode == .automatic else { return nil }
        if let cooldownUntil = store.snapshot.automation.safetyCooldownUntil,
           cooldownUntil > Date() {
            return "后台已停止，请于 \(cooldownUntil.formatted(date: .abbreviated, time: .shortened)) 后检查账号并手动启动。"
        }
        if !challengedAccounts.isEmpty, !hasRunnableAuthenticatedAccount {
            return "请完成 BOSS 本人验证后重试。"
        }
        if !canStartAutomaticWorker, !bossAutomation.isWorkerRunning { return readinessMessage }
        if bossAutomation.isWorkerRunning, !hasAutomationReadyAccount {
            return "已启动，等待登录就绪。"
        }
        if hasAuthenticatedAccount, !hasAutomationReadyAccount {
            return "登录准备中，可先启动任务。"
        }
        return nil
    }

    private var runHintColor: Color {
        canStartAutomaticWorker || bossAutomation.isWorkerRunning ? .secondary : .orange
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AutomationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.snapshot.automation[keyPath: keyPath] },
            set: { value in store.updateAutomation { $0[keyPath: keyPath] = value } }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AutomationSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.snapshot.automation[keyPath: keyPath] },
            set: { value in store.updateAutomation { $0[keyPath: keyPath] = value } }
        )
    }

    private func automaticTaskBinding(_ keyPath: WritableKeyPath<AutomationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.snapshot.automation[keyPath: keyPath] },
            set: { value in
                store.updateAutomation { $0[keyPath: keyPath] = value }
                reconcileAutomaticResumeEligibility()
                if !store.snapshot.automation.automaticallySearchJobs,
                   !store.snapshot.automation.automaticallyMonitorMessages {
                    bossAutomation.stopWorker(using: store)
                }
            }
        )
    }

    private var automaticResumeBinding: Binding<Bool> {
        Binding(
            get: { store.snapshot.automation.automaticallySendResume },
            set: { value in
                let shouldEnable = value && canEnableAutomaticResume
                store.updateAutomation { $0.automaticallySendResume = shouldEnable }
                if !shouldEnable {
                    for account in store.snapshot.accounts where account.status == .active {
                        bossAutomation.invalidateOperations(accountID: account.id)
                    }
                }
            }
        )
    }

    private var canEnableAutomaticResume: Bool {
        store.snapshot.automation.mode == .automatic &&
        store.snapshot.automation.automaticallyMonitorMessages
    }

    private var automaticResumeUnavailableReason: String? {
        if store.snapshot.automation.mode != .automatic {
            return "请先切换至“自动运行”。"
        }
        if !store.snapshot.automation.automaticallyMonitorMessages {
            return "请先开启“自动同步消息”。"
        }
        return nil
    }

    private func reconcileAutomaticResumeEligibility() {
        guard store.snapshot.automation.automaticallySendResume,
              !canEnableAutomaticResume else { return }
        store.updateAutomation { $0.automaticallySendResume = false }
        for account in store.snapshot.accounts where account.status == .active {
            bossAutomation.invalidateOperations(accountID: account.id)
        }
    }

    private var hasAutomationReadyAccount: Bool {
        store.snapshot.accounts.contains { account in
            account.status == .active &&
                account.manualVerificationChallenge == nil &&
                bossSessions.existingSession(for: account.id)?.automationReady == true
        }
    }

    private var challengedAccounts: [BossAccount] {
        store.snapshot.accounts.filter {
            $0.status == .active && $0.manualVerificationChallenge != nil
        }
    }

    private var hasRunnableAuthenticatedAccount: Bool {
        store.snapshot.accounts.contains { account in
            account.status == .active &&
                account.manualVerificationChallenge == nil &&
                bossSessions.existingSession(for: account.id)?.phase.isAuthenticated == true
        }
    }

    private var hasAuthenticatedAccount: Bool {
        store.snapshot.accounts.contains { account in
            account.status == .active && bossSessions.existingSession(for: account.id)?.phase.isAuthenticated == true
        }
    }

    private var hasRecoveringAccount: Bool {
        store.snapshot.accounts.contains { account in
            guard account.status == .active,
                  account.loginStatus == .loggedIn else { return false }
            guard let phase = bossSessions.existingSession(for: account.id)?.phase else { return true }
            return phase == .idle || phase == .restoring
        }
    }

    private var canStartAutomaticWorker: Bool {
        store.snapshot.automation.mode == .automatic &&
        store.snapshot.automation.safetyCooldownUntil.map { $0 > Date() } != true &&
        hasRunnableAuthenticatedAccount &&
        store.snapshot.resume.hasStoredAttachment &&
        (store.snapshot.automation.automaticallySearchJobs || store.snapshot.automation.automaticallyMonitorMessages) &&
        (!store.snapshot.automation.automaticallySearchJobs || store.snapshot.preferences.hasSearchCriteria)
    }

    private var readinessMessage: String {
        if store.snapshot.automation.mode != .automatic { return "未开启自动任务，可从总览手动同步。" }
        if !challengedAccounts.isEmpty, !hasRunnableAuthenticatedAccount {
            return "请在 BOSS 完成验证后重新检查。"
        }
        if !hasAuthenticatedAccount {
            return hasRecoveringAccount ? "正在恢复已保存的 BOSS 登录会话，无需重新扫码。" : "请先扫码登录至少一个 BOSS 账号。"
        }
        if !store.snapshot.resume.hasStoredAttachment {
            return "请到“求职偏好”添加简历。"
        }
        if store.snapshot.automation.automaticallySearchJobs,
           !store.snapshot.preferences.hasSearchCriteria {
            return "请填写求职要求，或关闭自动检索。"
        }
        if !store.snapshot.automation.automaticallySearchJobs && !store.snapshot.automation.automaticallyMonitorMessages {
            return "请至少开启自动检索或消息同步。"
        }
        return "配置已就绪。"
    }

    private var automationStatusTitle: String {
        if !challengedAccounts.isEmpty, !hasRunnableAuthenticatedAccount { return "等待本人验证" }
        if bossAutomation.isWorkerRunning, !hasAutomationReadyAccount { return "等待会话准备" }
        if bossAutomation.isWorkerRunning { return "自动运行中" }
        if bossAutomation.isCycleRunning { return "本次同步中" }
        if hasRecoveringAccount { return "正在恢复登录" }
        return "已停止"
    }

    private var automationStatusIcon: String {
        if !challengedAccounts.isEmpty, !hasRunnableAuthenticatedAccount { return "person.badge.shield.checkmark" }
        if bossAutomation.isWorkerRunning, !hasAutomationReadyAccount { return "hourglass" }
        if bossAutomation.isWorkerRunning { return "checkmark.circle.fill" }
        if bossAutomation.isCycleRunning { return "arrow.triangle.2.circlepath" }
        if hasRecoveringAccount { return "arrow.triangle.2.circlepath" }
        return "pause.circle"
    }

    private var automationStatusColor: Color {
        if !challengedAccounts.isEmpty, !hasRunnableAuthenticatedAccount { return .orange }
        if bossAutomation.isWorkerRunning, !hasAutomationReadyAccount { return .orange }
        if bossAutomation.isWorkerRunning { return .green }
        if bossAutomation.isCycleRunning { return BossPilotTheme.accent }
        if hasRecoveringAccount { return BossPilotTheme.accent }
        return .secondary
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
}

private struct AutomationCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BossPilotTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(BossPilotTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

struct CodexSettingsTab: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var codex: CodexController

    var body: some View {
        Form {
            Section("服务授权") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(codex.health?.version ?? "尚未检查")
                            .font(.headline)
                        Text(codexStatusDetail)
                            .font(.caption)
                            .foregroundStyle(codex.health?.supportsHardenedInvocation == false ? .orange : .secondary)
                    }
                    Spacer()
                    Button {
                        Task { await codex.check(using: store) }
                    } label: {
                        if codex.isChecking { ProgressView().controlSize(.small) } else { Text("重新检查") }
                    }
                    .disabled(codex.isChecking)
                }
                HStack {
                    Label(codex.isAuthorized ? "已授权" : "未授权", systemImage: codex.isAuthorized ? "checkmark.shield" : "lock")
                        .foregroundStyle(codex.isAuthorized ? Color.green : .secondary)
                    Spacer()
                    if codex.isAuthorizing {
                        ProgressView().controlSize(.small)
                        if let url = codex.authorizationURL {
                            Link("打开授权页", destination: url)
                        }
                        Button("取消授权") { Task { await codex.revokeAuthorization(using: store) } }
                    } else if codex.isAuthorized {
                        Button("退出授权") { Task { await codex.revokeAuthorization(using: store) } }
                    } else {
                        Button("登录授权") { codex.authorize(using: store) }
                            .buttonStyle(.borderedProminent)
                            .disabled(codex.health?.supportsHardenedInvocation != true)
                    }
                }
                .disabled(codex.isRevokingAuthorization)
            }

            Section("分析能力") {
                HStack {
                    Picker("模型", selection: modelBinding) {
                        Text("自动选择").tag("")
                        ForEach(codex.models) { option in
                            Text(option.displayName).tag(option.model)
                        }
                        if !store.snapshot.codex.model.isEmpty,
                           !codex.models.contains(where: { $0.model == store.snapshot.codex.model }) {
                            Text(store.snapshot.codex.model).tag(store.snapshot.codex.model)
                        }
                    }
                    Button {
                        Task { await codex.loadModels(using: store, refresh: true) }
                    } label: {
                        if codex.isLoadingModels { ProgressView().controlSize(.small) } else { Text("刷新模型") }
                    }
                    .disabled(codex.isLoadingModels || codex.isAuthorizing || codex.isRevokingAuthorization)
                }
                if let error = codex.modelListError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                Toggle("岗位匹配评估", isOn: analysisBinding(\.enableJobAssessment))
                    .help("开启后允许向 Codex 发送评估所需的岗位与画像")
                Toggle("招聘消息分析", isOn: analysisBinding(\.enableReplyDrafting))
                    .help("开启后允许向 Codex 发送分析所需的岗位与画像；消息发送另由数据授权控制")
                Picker("推理强度", selection: codexStringBinding(\.reasoningEffort)) {
                    ForEach(reasoningOptions, id: \.self) { effort in
                        Text(reasoningTitle(effort)).tag(effort)
                    }
                }
            }

            Section("数据授权") {
                Toggle("允许发送招聘消息", isOn: Binding(
                    get: { store.snapshot.automation.allowRecruiterTextToCodex },
                    set: { value in store.updateAutomation { $0.allowRecruiterTextToCodex = value } }
                ))
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .task {
            if codex.health == nil, !codex.isChecking { await codex.check(using: store) }
            await codex.loadModels(using: store)
        }
        .onChange(of: codex.models) { _, options in
            if let selected = options.first(where: { $0.model == store.snapshot.codex.model }),
               !selected.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == store.snapshot.codex.reasoningEffort }) {
                store.updateCodex { $0.reasoningEffort = selected.defaultReasoningEffort }
            }
        }
    }

    private var reasoningOptions: [String] {
        if let selected = codex.models.first(where: { $0.model == store.snapshot.codex.model }),
           !selected.supportedReasoningEfforts.isEmpty {
            return selected.supportedReasoningEfforts.map(\.reasoningEffort)
        }
        let standard = ["low", "medium", "high"]
        let current = store.snapshot.codex.reasoningEffort
        return standard.contains(current) ? standard : standard + [current]
    }

    private var modelBinding: Binding<String> {
        Binding(get: { store.snapshot.codex.model }, set: { model in
            store.updateCodex { configuration in
                configuration.model = model
                if let option = codex.models.first(where: { $0.model == model }),
                   !option.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == configuration.reasoningEffort }) {
                    configuration.reasoningEffort = option.defaultReasoningEffort
                }
                if model.isEmpty, !["low", "medium", "high"].contains(configuration.reasoningEffort) { configuration.reasoningEffort = "medium" }
            }
        })
    }

    private func reasoningTitle(_ value: String) -> String {
        ["none": "关闭", "minimal": "最低", "low": "低", "medium": "中", "high": "高",
         "xhigh": "极高", "max": "最高", "ultra": "极致"][value] ?? value
    }

    private var codexStatusDetail: String {
        guard let health = codex.health else { return "点击检查本机 Codex 可用性" }
        return health.supportsHardenedInvocation ? "CLI 已就绪" : "版本缺少安全隔离参数，业务数据发送已禁用"
    }

    private func analysisBinding(_ keyPath: WritableKeyPath<CodexConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.snapshot.codex.allowJobDataToCodex && store.snapshot.codex[keyPath: keyPath] },
            set: { value in store.updateCodex { $0.setAnalysisEnabled(value, for: keyPath) } }
        )
    }

    private func codexStringBinding(_ keyPath: WritableKeyPath<CodexConfiguration, String>) -> Binding<String> {
        Binding(
            get: { store.snapshot.codex[keyPath: keyPath] },
            set: { value in store.updateCodex { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct ResumeAttachmentButton: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button("简历附件", systemImage: "doc.text") { openDirectory(attachmentsDirectory) }
            .buttonStyle(.bordered)
            .help("打开本地简历目录：\(attachmentsDirectory.path)")
    }

    private var attachmentsDirectory: URL {
        if let path = store.snapshot.resume.attachmentPath, !path.isEmpty {
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return store.localStateURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    private func openDirectory(_ directory: URL) {
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }.value
                if !NSWorkspace.shared.open(directory) {
                    store.lastError = "无法打开目录：\(directory.path)"
                }
            } catch { store.report(error) }
        }
    }
}
