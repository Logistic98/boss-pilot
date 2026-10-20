import SwiftUI

private enum JobListFilter: String, CaseIterable, Identifiable {
    case recommended
    case contacted
    case exchanged
    case filtered
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: "推荐"
        case .contacted: "已开聊"
        case .exchanged: "已交换"
        case .filtered: "已过滤"
        case .all: "全部"
        }
    }
}

struct JobsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var codex: CodexController
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    @EnvironmentObject private var bossAutomation: BossAutomationController
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var selectedFilter = JobListFilter.recommended
    @State private var selectedJobID: String?
    @State private var isManualVerificationRechecking = false
    @State private var batchIDs: Set<String> = []
    @State private var confirmingBatchDelete = false
    let navigate: (SidebarDestination) -> Void

    private var selectedAccount: BossAccount? {
        store.filteredAccounts.first
    }

    private var accountJobs: [JobListing] {
        let accountIDs = Set(store.filteredAccounts.map(\.id))
        return store.jobsInDisplayOrder.filter { job in
            let isBossRecord = job.id.hasPrefix("boss-") || job.securityID?.isEmpty == false
            let accountMatches = accountIDs.contains(job.accountID)
            let searchMatches = searchText.isEmpty || job.evidenceText.localizedCaseInsensitiveContains(searchText)
            return isBossRecord && accountMatches && searchMatches
        }
    }

    private var visibleJobs: [JobListing] {
        accountJobs
            .filter { job in
                let hasResumeExchange = store.hasResumeExchange(for: job)
                return switch selectedFilter {
                case .recommended:
                    job.stage == .recommended && !hasResumeExchange
                case .contacted:
                    job.stage.belongsToContactedCategory && !hasResumeExchange
                case .exchanged:
                    hasResumeExchange
                case .filtered:
                    [.rejected, .closed].contains(job.stage) && !hasResumeExchange
                case .all:
                    true
                }
            }

    }

    private var selectionContext: StableListSelectionContext {
        StableListSelectionContext(
            scopeID: store.selectedAccountID,
            mode: "\(selectedFilter.rawValue)|\(searchText)",
            visibleIDs: visibleJobs.map(\.id),
            preferredID: store.selectedJobID
        )
    }

    var body: some View {
        let visibleJobs = visibleJobs
        let selectedJob = visibleJobs.first { $0.id == selectedJobID }
        let selectionContext = StableListSelectionContext(
            scopeID: store.selectedAccountID,
            mode: "\(selectedFilter.rawValue)|\(searchText)",
            visibleIDs: visibleJobs.map(\.id),
            preferredID: store.selectedJobID
        )
        return VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "岗位列表",
                subtitle: "查看岗位和匹配结果。",
                systemImage: "briefcase"
            ) {
                HStack(spacing: 10) {
                    StatusPill(title: "\(visibleJobs.count) 个岗位", systemImage: "tray.full.fill", color: BossPilotTheme.accent)
                    refreshJobsButton
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()

            if let account = selectedAccount,
               let challenge = account.manualVerificationChallenge {
                BossManualVerificationBanner(
                    accountLabel: account.selectionLabel(in: store.snapshot.accounts),
                    challenge: challenge,
                    isRechecking: isManualVerificationRechecking,
                    openVerificationPage: {
                        openVerificationPage(account: account, challenge: challenge)
                    },
                    recheck: { recheckManualVerification(for: account) }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
            }

            Picker("岗位筛选", selection: $selectedFilter) {
                ForEach(JobListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("岗位筛选")
            .frame(maxWidth: 560)
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .fixedSize(horizontal: false, vertical: true)
            Divider()

            if !visibleJobs.isEmpty {
                HStack(spacing: 12) {
                    Button("全选") { batchIDs = Set(visibleJobs.map(\.id)) }
                        .disabled(visibleJobs.isEmpty)
                    Button("取消选择") { batchIDs.removeAll() }
                        .disabled(batchIDs.isEmpty)
                    Text("已选 \(batchIDs.count) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除所选", role: .destructive) { confirmingBatchDelete = true }
                        .disabled(batchIDs.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            if visibleJobs.isEmpty {
                jobsEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    HSplitView {
                        jobList(visibleJobs)
                            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)

                        Group {
                            if let job = selectedJob {
                                JobDetailView(job: job)
                                    .id(job.id)
                            } else {
                                EmptyStateView(
                                    title: "选择一个岗位",
                                    detail: "查看 BOSS 原始岗位证据和本地匹配结论。",
                                    systemImage: "briefcase"
                                )
                            }
                        }
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("")
        .alert("删除所选的 \(batchIDs.count) 项本地记录？", isPresented: $confirmingBatchDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                store.removeJobs(ids: batchIDs)
                batchIDs.removeAll()
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索已同步岗位或公司")
        .task {
            await Task.yield()
            ensureAccountSelection()
        }
        .task(id: selectionContext) {
            batchIDs.formIntersection(selectionContext.visibleIDs)
            await Task.yield()
            reconcileSelection(using: selectionContext)
        }
        .onChange(of: selectedJobID) { _, jobID in
            persistSelectionAfterViewUpdate(jobID)
        }
    }

    private func jobList(_ visibleJobs: [JobListing]) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(visibleJobs) { job in
                    HStack(spacing: 6) {
                        Toggle("选择记录", isOn: Binding(
                            get: { batchIDs.contains(job.id) },
                            set: { selected in
                                if selected { batchIDs.insert(job.id) } else { batchIDs.remove(job.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Button {
                        selectedJobID = job.id
                    } label: {
                        JobRow(
                            job: job,
                            hasResumeExchange: store.hasResumeExchange(for: job),
                            resumeExchangeDate: store.resumeExchangeDate(for: job)
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedJobID == job.id ? BossPilotTheme.accent.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            store.removeJob(id: job.id)
                        } label: {
                            Label("删除本地岗位", systemImage: "trash")
                        }
                        .help("仅删除本地记录和关联待办，后续同步可能重新出现")
                    }
                    }
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var refreshJobsButton: some View {
        Button {
            startBossSearch()
        } label: {
            Label("刷新 BOSS 岗位", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(searchButtonDisabled)
        .help(searchReadinessMessage)
    }

    private var jobsEmptyState: some View {
        WorkspaceEmptyState(title: emptyTitle, detail: emptyDetail, systemImage: emptySystemImage) {
            HStack(spacing: 8) {
                if !searchText.isEmpty {
                    Button("清除搜索") { searchText = "" }
                        .buttonStyle(.borderedProminent)
                } else if !accountJobs.isEmpty, selectedFilter != .all {
                    Button("查看全部岗位") { selectedFilter = .all }
                        .buttonStyle(.borderedProminent)
                } else if store.snapshot.accounts.isEmpty {
                    Button("扫码登录 BOSS") { navigate(.accounts) }
                        .buttonStyle(.borderedProminent)
                } else if !store.snapshot.resume.hasStoredAttachment || !store.snapshot.preferences.hasSearchCriteria {
                    Button("打开要求") { navigate(.setup) }
                        .buttonStyle(.borderedProminent)
                } else if !store.snapshot.automation.allowsConnectorReads {
                    Button("调整运行模式") { navigate(.automation) }
                        .buttonStyle(.borderedProminent)
                } else if let account = selectedAccount,
                          bossSessions.existingSession(for: account.id)?.automationReady != true {
                    Button("检查账号登录") { navigate(.accounts) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var emptyTitle: String {
        if store.snapshot.accounts.isEmpty { return "还没有连接 BOSS" }
        if !searchText.isEmpty { return "未找到相关岗位" }
        if !accountJobs.isEmpty { return "暂无\(selectedFilter.title)岗位" }
        if !store.snapshot.resume.hasStoredAttachment || !store.snapshot.preferences.hasSearchCriteria { return "要求尚未完成" }
        if selectedAccount == nil { return "选择一个 BOSS 账号" }
        if selectedAccount?.manualVerificationChallenge != nil { return "BOSS 需要本人验证" }
        if !store.snapshot.automation.allowsConnectorReads { return "当前模式不读取 BOSS" }
        if let account = selectedAccount,
           bossSessions.existingSession(for: account.id)?.automationReady != true {
            return "账号会话尚未就绪"
        }
        return "BOSS 暂未返回岗位"
    }

    private var emptyDetail: String {
        if store.snapshot.accounts.isEmpty { return "添加账号并登录后同步岗位。" }
        if !searchText.isEmpty { return "试试其他关键词，或清除搜索。" }
        if !accountJobs.isEmpty { return "切换筛选查看其他岗位。" }
        if !store.snapshot.resume.hasStoredAttachment { return "请先添加简历。" }
        if !store.snapshot.preferences.hasSearchCriteria { return "请先填写求职要求。" }
        if selectedAccount == nil { return "在顶部选择要查看的账号。" }
        if selectedAccount?.manualVerificationChallenge != nil { return "请在 BOSS 完成验证后重新检查。" }
        if !store.snapshot.automation.allowsConnectorReads { return "“仅提醒”不访问 BOSS，可在设置中切换到辅助或自动模式。" }
        if let account = selectedAccount,
           bossSessions.existingSession(for: account.id)?.automationReady != true {
            return "请先在账号中完成扫码或会话恢复。"
        }
        return "当前账号与检索条件没有返回岗位，可稍后刷新或调整要求。"
    }

    private var emptySystemImage: String {
        store.snapshot.accounts.isEmpty ? "person.crop.circle.badge.plus" : "briefcase"
    }

    private func reconcileSelection(using context: StableListSelectionContext) {
        guard context == selectionContext else { return }
        let nextSelection = StableListSelectionPolicy.reconciledSelection(
            current: selectedJobID,
            preferred: context.preferredID,
            visibleIDs: context.visibleIDs
        )
        if selectedJobID != nextSelection {
            selectedJobID = nextSelection
        } else if store.selectedJobID != nextSelection {
            store.selectedJobID = nextSelection
        }
    }

    private func persistSelectionAfterViewUpdate(_ jobID: String?) {
        Task { @MainActor in
            await Task.yield()
            guard selectedJobID == jobID else { return }
            let visibleIDs = Set(visibleJobs.map(\.id))
            let isValidSelection = if let jobID {
                visibleIDs.contains(jobID)
            } else {
                visibleIDs.isEmpty
            }
            guard isValidSelection else { return }
            if store.selectedJobID != jobID {
                store.selectedJobID = jobID
            }
        }
    }

    private func ensureAccountSelection() {
        if selectedAccount == nil {
            store.selectedAccountID = store.snapshot.accounts.first(where: { $0.status == .active })?.id
                ?? store.snapshot.accounts.first?.id
        }
    }

    private var searchButtonDisabled: Bool {
        guard let account = store.filteredAccounts.first(where: { $0.manualVerificationChallenge == nil && bossSessions.existingSession(for: $0.id)?.automationReady == true }) else { return true }
        let accountID = account.id
        return bossAutomation.runningAccountIDs.contains(accountID)
            || account.manualVerificationChallenge != nil
            || !store.snapshot.resume.hasStoredAttachment
            || !store.snapshot.preferences.hasSearchCriteria
            || !store.snapshot.automation.allowsConnectorReads
            || bossSessions.existingSession(for: accountID)?.automationReady != true
    }

    private var searchReadinessMessage: String {
        guard let account = selectedAccount else { return "请选择一个 BOSS 账号。" }
        let accountID = account.id
        if let challenge = account.manualVerificationChallenge { return challenge.userFacingReason }
        if !store.snapshot.automation.allowsConnectorReads { return "仅提醒模式不会访问 BOSS，请先切换到辅助模式或自动运行。" }
        if bossSessions.existingSession(for: accountID)?.automationReady != true { return "登录尚未就绪，请到“账号管理”检查。" }
        if !store.snapshot.resume.hasStoredAttachment { return "请先在“求职偏好”中添加附件简历。" }
        if !store.snapshot.preferences.hasSearchCriteria { return "请先在“求职偏好”中写下自然语言求职要求。" }
        return "数据来源：BOSS；同步后自动执行本地匹配评估。"
    }

    private func startBossSearch() {
        let accounts = store.filteredAccounts.filter {
            $0.manualVerificationChallenge == nil && bossSessions.existingSession(for: $0.id)?.automationReady == true
        }
        Task {
            for account in accounts {
                let session = bossSessions.session(for: account)
                await session.restoreIfNeeded()
                await bossAutomation.searchJobs(account: account, session: session, store: store, codex: codex)
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
              !isManualVerificationRechecking else { return }
        isManualVerificationRechecking = true
        let session = bossSessions.session(for: account)
        Task {
            await session.restoreIfNeeded()
            _ = await bossAutomation.recheckManualVerification(
                account: account,
                session: session,
                store: store
            )
            isManualVerificationRechecking = false
        }
    }
}

private struct JobRow: View {
    let job: JobListing
    let hasResumeExchange: Bool
    let resumeExchangeDate: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text([job.company, job.salary].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if hasResumeExchange {
                    Text(resumeExchangeDate.map { "交换于 \($0.formatted(date: .numeric, time: .shortened))" } ?? "交换时间未记录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(hasResumeExchange ? JobStage.resumeSent.title : job.stage.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        job.stage == .recommended || hasResumeExchange ? .green : .secondary
                    )
                if let score = job.assessment?.score {
                    Text("\(score)")
                        .font(.caption.bold())
                        .foregroundStyle(score >= 75 ? .green : score >= 60 ? .orange : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("匹配分数 \(score) 分")
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct JobDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let job: JobListing

    private var currentJob: JobListing {
        store.snapshot.jobs.first(where: { $0.id == job.id }) ?? job
    }

    private var account: BossAccount? {
        store.snapshot.accounts.first { $0.id == currentJob.accountID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewCard

                if let assessment = currentJob.assessment {
                    AssessmentView(assessment: assessment)
                } else {
                    EmptyStateView(title: "等待自动评估", detail: "同步后按简历和要求评估。", systemImage: "chart.bar.doc.horizontal")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("职位描述")
                        .font(.title3.bold())
                    if !currentJob.hasAuthoritativeDescription {
                        Text("缺少职位描述，暂不评估或开聊。")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(currentJob.description)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .panelStyle()
            }
            .padding(24)
        }
    }

    private func openOfficialJob() {
        guard let account else { return }
        openWindow(
            value: BossOfficialPageRequest(
                accountID: account.id,
                title: currentJob.title.isEmpty ? "BOSS 岗位页" : "BOSS 岗位页 · \(currentJob.title)",
                initialURL: OfficialBossLinkService.url(for: currentJob)
            )
        )
    }

    private var overviewCard: some View {
        let exchanged = store.hasResumeExchange(for: currentJob)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(currentJob.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(currentJob.company)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(currentJob.salary.isEmpty ? "薪资未提供" : currentJob.salary)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(BossPilotTheme.accent)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 12) {
                    StatusPill(title: exchanged ? JobStage.resumeSent.title : currentJob.stage.title,
                               systemImage: exchanged ? "checkmark.circle.fill" : "briefcase",
                               color: exchanged ? .green : .secondary)
                    Button("打开 BOSS 岗位页") { openOfficialJob() }
                        .disabled(account == nil)
                        .help("打开该账号的 BOSS 岗位页")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 12) {
                JobFact(label: "地点", value: currentJob.displayLocation)
                JobFact(label: "经验", value: currentJob.experience)
                JobFact(label: "学历", value: currentJob.education)
            }

            Divider()
            let companyFacts = [Optional(currentJob.displayIndustry), currentJob.companySize, currentJob.financingStage]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 12) {
                JobFact(label: "招聘方", value: currentJob.recruiterDisplayLabel)
                JobFact(label: "公司信息", value: companyFacts)
            }
            if exchanged {
                Divider()
                Label {
                    Text(store.resumeExchangeDate(for: currentJob).map {
                        "简历交换于 \($0.formatted(date: .numeric, time: .shortened))"
                    } ?? "简历已交换 · 时间未记录")
                    .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "doc.badge.arrow.up").foregroundStyle(.green)
                }
                .font(.callout)
            }
        }
        .panelStyle()
    }
}

private struct JobFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "未提供" : value)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssessmentView: View {
    let assessment: JobAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("匹配评估")
                        .font(.title3.bold())
                    Text("\(assessment.provider) · 置信度\(assessment.confidence.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(assessment.score) 分")
                    .font(.title.bold())
                Text(assessment.recommendation)
                    .font(.headline)
            }

            if !assessment.reasons.isEmpty {
                Label("匹配依据", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                ForEach(assessment.reasons, id: \.self) { Text("• \($0)") }
            }

            if !assessment.risks.isEmpty {
                Label("风险与缺口", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(assessment.risks, id: \.self) { Text("• \($0)") }
            }


        }
        .panelStyle()
    }
}
