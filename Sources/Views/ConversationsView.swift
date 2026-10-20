import AppKit
import SwiftUI

private enum ConversationListFilter: String, CaseIterable, Identifiable {
    case attention
    case processed
    case active
    case filtered
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention: "待处理"
        case .processed: "已处理"
        case .active: "仅沟通"
        case .filtered: "已过滤"
        case .all: "全部"
        }
    }
}

struct ConversationsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossSessions: BossSessionCoordinator
    @EnvironmentObject private var bossAutomation: BossAutomationController
    @Environment(\.openWindow) private var openWindow
    @State private var selectedFilter = ConversationListFilter.attention
    @State private var selectedConversationID: String?
    @State private var isManualVerificationRechecking = false
    @State private var batchIDs: Set<String> = []
    @State private var confirmingBatchDelete = false
    let navigate: (SidebarDestination) -> Void

    private var selectedAccount: BossAccount? {
        store.filteredAccounts.first
    }

    private var accountConversations: [Conversation] {
        return store.snapshot.conversations.filter { conversation in
            let isBossRecord = conversation.remoteConversationID != nil || conversation.id.hasPrefix("boss-")
            let accountMatches = store.includesAccount(conversation.accountID)
            return isBossRecord && accountMatches
        }
    }

    private var accountRows: [(conversation: Conversation, state: ConversationWorkState)] {
        store.conversationDisplayRows.filter {
            store.includesAccount($0.conversation.accountID) &&
                ($0.conversation.remoteConversationID != nil || $0.conversation.id.hasPrefix("boss-"))
        }
    }

    private var visibleConversations: [Conversation] {
        filteredConversations(accountRows)
    }

    private func filteredConversations(
        _ rows: [(conversation: Conversation, state: ConversationWorkState)]
    ) -> [Conversation] {
        rows.filter { _, state in
                return switch selectedFilter {
                case .attention: state == .pending
                case .processed: state == .processed
                case .active: state == .active
                case .filtered: state == .filtered
                case .all: true
                }
            }
            .map(\.conversation)
    }

    private var selectionContext: StableListSelectionContext {
        StableListSelectionContext(
            scopeID: store.selectedAccountID,
            mode: selectedFilter.rawValue,
            visibleIDs: visibleConversations.map(\.id),
            preferredID: store.selectedConversationID
        )
    }

    var body: some View {
        let rows = accountRows
        let visibleConversations = filteredConversations(rows)
        let attentionCount = rows.filter { $0.state == .pending }.count
        let states = Dictionary(rows.map { ($0.conversation.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let selectedConversation = visibleConversations.first { $0.id == selectedConversationID }
        let selectionContext = StableListSelectionContext(
            scopeID: store.selectedAccountID,
            mode: selectedFilter.rawValue,
            visibleIDs: visibleConversations.map(\.id),
            preferredID: store.selectedConversationID
        )
        return VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "沟通会话",
                subtitle: "查看沟通记录和简历进度。",
                systemImage: "bubble.left.and.bubble.right"
            ) {
                HStack(spacing: 10) {
                    StatusPill(
                        title: "\(attentionCount) 项待处理",
                        systemImage: "checklist",
                        color: attentionCount > 0 ? .orange : .secondary
                    )
                    refreshMessagesButton
                    openMessagesButton(for: selectedConversation)
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

            Picker("消息筛选", selection: $selectedFilter) {
                ForEach(ConversationListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("消息筛选")
            .frame(maxWidth: 440)
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .fixedSize(horizontal: false, vertical: true)
            Divider()

            if !visibleConversations.isEmpty {
                HStack(spacing: 12) {
                    Button("全选") { batchIDs = Set(visibleConversations.map(\.id)) }
                        .disabled(visibleConversations.isEmpty)
                    Button("取消选择") { batchIDs.removeAll() }
                        .disabled(batchIDs.isEmpty)
                    Text("已选 \(batchIDs.count) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("标记已处理") { store.markConversationsHandled(ids: batchIDs); batchIDs.removeAll() }
                        .disabled(batchIDs.isEmpty)
                    Button("删除所选", role: .destructive) { confirmingBatchDelete = true }
                        .disabled(batchIDs.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            if visibleConversations.isEmpty {
                conversationEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    HSplitView {
                        conversationList(visibleConversations, states: states)
                            .frame(minWidth: 280, idealWidth: 320)

                        // 面板宽度不随选中消息的内容长度变化。
                        GeometryReader { detailProxy in
                            Group {
                                if let conversation = selectedConversation {
                                    ConversationDetailView(
                                        conversation: conversation,
                                        workState: states[conversation.id] ?? .active
                                    )
                                        .id(conversation.id)
                                } else {
                                    EmptyStateView(
                                        title: "选择一条沟通摘要",
                                        detail: "查看沟通记录和简历进度。",
                                        systemImage: "bubble.left"
                                    )
                                }
                            }
                            .frame(width: detailProxy.size.width, height: detailProxy.size.height, alignment: .topLeading)
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
                store.removeConversations(ids: batchIDs)
                batchIDs.removeAll()
            }
        }
        .task {
            await Task.yield()
            ensureAccountSelection()
        }
        .task(id: selectionContext) {
            batchIDs.formIntersection(selectionContext.visibleIDs)
            await Task.yield()
            reconcileSelection(using: selectionContext)
        }
        .onChange(of: selectedConversationID) { _, conversationID in
            persistSelectionAfterViewUpdate(conversationID)
        }
    }

    private func conversationList(
        _ visibleConversations: [Conversation], states: [String: ConversationWorkState]
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(visibleConversations) { conversation in
                    HStack(spacing: 6) {
                        Toggle("选择记录", isOn: Binding(
                            get: { batchIDs.contains(conversation.id) },
                            set: { selected in
                                if selected { batchIDs.insert(conversation.id) } else { batchIDs.remove(conversation.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Button {
                        selectedConversationID = conversation.id
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            workState: states[conversation.id] ?? .active
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedConversationID == conversation.id
                            ? BossPilotTheme.accent.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            store.removeConversation(id: conversation.id)
                        } label: {
                            Label("删除本地会话", systemImage: "trash")
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

    private var refreshMessagesButton: some View {
        Button {
            synchronizeMessages()
        } label: {
            Label("刷新 BOSS 消息", systemImage: "arrow.clockwise")
        }
        .disabled(syncButtonDisabled)
        .help(readinessMessage)
    }

    private func openMessagesButton(for conversation: Conversation?) -> some View {
        let account = if let conversation {
            store.filteredAccounts.first { $0.id == conversation.accountID }
        } else {
            store.filteredAccounts.first { bossSessions.existingSession(for: $0.id)?.phase.isAuthenticated == true }
        }
        let canOpen = account.map { bossSessions.existingSession(for: $0.id)?.phase.isAuthenticated == true } ?? false
        return Button {
            guard canOpen, let account else { return }
            openWindow(value: BossOfficialPageRequest(
                accountID: account.id,
                title: conversation.map { "BOSS 消息页 · \($0.recruiterName)" } ?? "BOSS 消息页",
                initialURL: OfficialBossLinkService.chat
            ))
        } label: {
            Label("打开 BOSS 消息页", systemImage: "macwindow")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canOpen)
        .help(canOpen ? "打开当前会话所属账号的 BOSS 消息页" : "请先完成账号的 BOSS 登录")
    }

    private var conversationEmptyState: some View {
        WorkspaceEmptyState(title: emptyTitle, detail: emptyDetail, systemImage: emptySystemImage) {
            HStack(spacing: 8) {
                if !accountConversations.isEmpty, selectedFilter != .all {
                    Button("查看全部消息") { selectedFilter = .all }
                        .buttonStyle(.borderedProminent)
                } else if store.snapshot.accounts.isEmpty {
                    Button("扫码登录 BOSS") { navigate(.accounts) }
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
        if selectedAccount == nil { return "选择一个 BOSS 账号" }
        if !accountConversations.isEmpty { return "暂无\(selectedFilter.title)消息" }
        if selectedAccount?.manualVerificationChallenge != nil { return "BOSS 需要本人验证" }
        if !store.snapshot.automation.allowsConnectorReads { return "当前模式不读取 BOSS" }
        if let account = selectedAccount,
           bossSessions.existingSession(for: account.id)?.automationReady != true {
            return "账号会话尚未就绪"
        }
        return "BOSS 暂未返回沟通摘要"
    }

    private var emptyDetail: String {
        if store.snapshot.accounts.isEmpty { return "添加账号并扫码登录。" }
        if selectedAccount == nil { return "在顶部选择要查看的账号。" }
        if !accountConversations.isEmpty { return "切换筛选查看其他消息。" }
        if selectedAccount?.manualVerificationChallenge != nil { return "请在 BOSS 完成验证后重新检查。" }
        if !store.snapshot.automation.allowsConnectorReads { return "“仅提醒”不访问 BOSS，可在设置中切换到辅助或自动模式。" }
        if let account = selectedAccount,
           bossSessions.existingSession(for: account.id)?.automationReady != true {
            return "请先在账号中完成扫码或会话恢复。"
        }
        return "暂无消息，请刷新或打开 BOSS 消息页。"
    }

    private var emptySystemImage: String {
        store.snapshot.accounts.isEmpty ? "person.crop.circle.badge.plus" : "bubble.left.and.bubble.right"
    }

    private func reconcileSelection(using context: StableListSelectionContext) {
        guard context == selectionContext else { return }
        let nextSelection = StableListSelectionPolicy.reconciledSelection(
            current: selectedConversationID,
            preferred: context.preferredID,
            visibleIDs: context.visibleIDs
        )
        if selectedConversationID != nextSelection {
            selectedConversationID = nextSelection
        } else if store.selectedConversationID != nextSelection {
            store.selectedConversationID = nextSelection
        }
    }

    private func persistSelectionAfterViewUpdate(_ conversationID: String?) {
        Task { @MainActor in
            await Task.yield()
            guard selectedConversationID == conversationID else { return }
            let visibleIDs = Set(visibleConversations.map(\.id))
            let isValidSelection = if let conversationID {
                visibleIDs.contains(conversationID)
            } else {
                visibleIDs.isEmpty
            }
            guard isValidSelection else {
                return
            }
            if store.selectedConversationID != conversationID {
                store.selectedConversationID = conversationID
            }
        }
    }

    private func ensureAccountSelection() {
        if selectedAccount == nil {
            store.selectedAccountID = store.snapshot.accounts.first(where: { $0.status == .active })?.id
                ?? store.snapshot.accounts.first?.id
        }
    }

    private func synchronizeMessages() {
        let accounts = store.filteredAccounts.filter {
            $0.manualVerificationChallenge == nil && bossSessions.existingSession(for: $0.id)?.automationReady == true
        }
        Task {
            for account in accounts {
                let session = bossSessions.session(for: account)
                await session.restoreIfNeeded()
                await bossAutomation.synchronizeMessages(account: account, session: session, store: store)
            }
        }
    }

    private var syncButtonDisabled: Bool {
        guard let account = store.filteredAccounts.first(where: { $0.manualVerificationChallenge == nil && bossSessions.existingSession(for: $0.id)?.automationReady == true }) else { return true }
        return bossAutomation.runningAccountIDs.contains(account.id)
            || account.manualVerificationChallenge != nil
            || !store.snapshot.automation.allowsConnectorReads
            || bossSessions.existingSession(for: account.id)?.automationReady != true
    }

    private var readinessMessage: String {
        guard let account = selectedAccount else { return "请选择一个 BOSS 账号。" }
        if let challenge = account.manualVerificationChallenge { return challenge.userFacingReason }
        if !store.snapshot.automation.allowsConnectorReads { return "仅提醒模式不会读取 BOSS；仍可打开 BOSS 消息页。" }
        if bossSessions.existingSession(for: account.id)?.automationReady != true { return "登录尚未就绪，请到“账号管理”检查。" }
        if let date = account.lastSyncAt { return "最近同步 \(date.formatted(date: .omitted, time: .shortened)) · 数据来自 BOSS" }
        return "可以同步 BOSS 消息和附件简历投递状态。"
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

private struct ConversationRow: View {
    let conversation: Conversation
    let workState: ConversationWorkState

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.recruiterName.isEmpty ? "招聘方" : conversation.recruiterName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(messageDate.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text([conversation.company, conversation.jobTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let latestMessage = conversation.latestMessage {
                    Text(latestMessage.displayText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if workState == .pending {
                    Text("待处理")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if workState == .processed {
                    Text("已处理")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                } else if workState == .filtered {
                    Text("已过滤")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(BossPilotTheme.accent, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var messageDate: Date {
        conversation.latestMessage?.sentAt
            ?? conversation.remoteUpdatedAt
            ?? conversation.lastSyncedAt
    }
}

private struct ConversationDetailView: View {
    @EnvironmentObject private var store: AppStore
    let conversation: Conversation
    let workState: ConversationWorkState

    private var displayableMessages: [ChatMessage] {
        conversation.displayableMessages.sorted { $0.sentAt < $1.sentAt }
    }

    private var pendingActions: [PendingAction] {
        store.snapshot.pendingActions
            .filter {
                $0.accountID == conversation.accountID &&
                $0.conversationID == conversation.id &&
                $0.status.requiresAttention
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var resumeDeliveryRecords: [ResumeDeliveryRecord] {
        store.snapshot.resumeDeliveryRecords
            .filter {
                $0.accountID == conversation.accountID &&
                    $0.conversationID == conversation.id
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    conversationIdentity
                    Spacer(minLength: 12)
                    conversationHeaderActions
                }

                VStack(alignment: .leading, spacing: 10) {
                    conversationIdentity
                    conversationHeaderActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !resumeDeliveryRecords.isEmpty {
                        ResumeDeliveryActivityPanel(
                            title: "本会话的附件简历",
                            detail: "已交换：BOSS 已接受；已送达：历史已核实。",
                            records: resumeDeliveryRecords,
                            accounts: store.snapshot.accounts,
                            conversations: store.snapshot.conversations,
                            collapsedCount: 3
                        )
                    }

                    ForEach(displayableMessages) { message in
                        SummaryMessageRow(message: message)
                    }

                    if !pendingActions.isEmpty {
                        draftActionsPanel
                    }
                }
                .padding(20)
            }
        }
    }

    private var conversationIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.recruiterName.isEmpty ? "招聘方" : conversation.recruiterName)
                .font(.title2.bold())
            Text([conversation.company, conversation.jobTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }

    private var conversationHeaderActions: some View {
        HStack(spacing: 8) {
            StatusPill(title: "来自 BOSS", systemImage: "checkmark.seal.fill", color: .green)
            if workState == .pending {
                Button("标记已处理") {
                    store.markConversationHandled(id: conversation.id)
                }
                .buttonStyle(.bordered)
                .help("关闭该会话当前待办；后续新消息会自动重新打开")
            }
        }
    }

    private var draftActionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "需要你确认", detail: "本地草稿与附件发送提示")
                Spacer()
                Text("\(pendingActions.count) 项")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(Array(pendingActions.enumerated()), id: \.element.id) { index, action in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(action.kind.title, systemImage: action.kind == .sendResume ? "doc.badge.arrow.up" : "text.bubble")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Button("标记完成") { store.setActionStatus(id: action.id, status: .completed) }
                            .buttonStyle(.bordered)
                        Button("忽略") { store.setActionStatus(id: action.id, status: .dismissed) }
                            .buttonStyle(.plain)
                    }
                    Text(action.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(action.content)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(action.content, forType: .string)
                            store.setActionStatus(id: action.id, status: .copied)
                        } label: {
                            Label(action.status == .copied ? "已复制" : "复制内容", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if index < pendingActions.count - 1 { Divider() }
            }
        }
        .panelStyle()
    }


}

private struct SummaryMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.direction == .incoming ? "arrow.down.left.circle.fill" : message.direction == .outgoing ? "arrow.up.right.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(message.direction == .incoming ? .purple : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.displayText)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(speaker)
                    Text(message.sentAt.formatted(date: .numeric, time: .shortened))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
    }

    private var speaker: String {
        switch message.direction {
        case .incoming: return "对方"
        case .outgoing: return "我"
        case .system: return "记录"
        }
    }
}

struct ResumeDeliveryActivityPanel: View {
    let title: String
    let detail: String
    let records: [ResumeDeliveryRecord]
    let accounts: [BossAccount]
    let conversations: [Conversation]
    let collapsedCount: Int
    var onSelect: ((ResumeDeliveryRecord) -> Void)? = nil

    @State private var showsAll = false

    private var sortedRecords: [ResumeDeliveryRecord] {
        records.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var displayedRecords: [ResumeDeliveryRecord] {
        showsAll ? sortedRecords : Array(sortedRecords.prefix(max(collapsedCount, 1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.bold())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(records.count) 条")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if records.count > max(collapsedCount, 1) {
                    Button(showsAll ? "收起" : "查看全部") {
                        withAnimation(.easeInOut(duration: 0.18)) { showsAll.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.bottom, 12)

            Divider()

            ForEach(Array(displayedRecords.enumerated()), id: \.element.id) { index, record in
                if let onSelect, conversation(for: record) != nil {
                    Button { onSelect(record) } label: {
                        ResumeDeliveryActivityRow(
                            record: record,
                            accountLabel: accountLabel(for: record),
                            conversationLabel: conversationLabel(for: record)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    ResumeDeliveryActivityRow(
                        record: record,
                        accountLabel: accountLabel(for: record),
                        conversationLabel: conversationLabel(for: record)
                    )
                }
                if index < displayedRecords.count - 1 { Divider() }
            }
        }
        .panelStyle()
    }

    private func accountLabel(for record: ResumeDeliveryRecord) -> String {
        accounts.first(where: { $0.id == record.accountID })?
            .selectionLabel(in: accounts) ?? "已移除账号·\(record.accountID.uuidString.prefix(8))"
    }

    private func conversation(for record: ResumeDeliveryRecord) -> Conversation? {
        conversations.first {
            $0.accountID == record.accountID && $0.id == record.conversationID
        }
    }

    private func conversationLabel(for record: ResumeDeliveryRecord) -> String {
        guard let conversation = conversation(for: record) else {
            return "会话 \(record.conversationID)"
        }
        let recruiter = conversation.recruiterName.isEmpty ? "招聘方" : conversation.recruiterName
        let context = [conversation.company, conversation.jobTitle]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return context.isEmpty ? recruiter : "\(recruiter) · \(context)"
    }
}

private struct ResumeDeliveryActivityRow: View {
    let record: ResumeDeliveryRecord
    let accountLabel: String
    let conversationLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)
                .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BossPilotTheme.accent)
                        .lineLimit(1)
                    Text(exchangeKindTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(conversationLabel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if record.state == .failed {
                    Label("失败原因：\(failureReason)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text(activityTimeline)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(statusTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.10), in: Capsule())
        }
        .contentShape(Rectangle())
        .padding(.vertical, 11)
    }

    private var statusTitle: String {
        switch record.state {
        case .queued: "排队中"
        case .preparingAttachment: "准备附件"
        case .dispatching: "正在提交"
        case .requestCreatedAwaitingRecruiter: "等待招聘方确认"
        case .serverAcceptedUnverified: "已交换·待回读"
        case .confirmed: "已确认送达"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private var statusDetail: String {
        switch record.state {
        case .queued:
            "等待提交。"
        case .preparingAttachment:
            "正在准备附件，尚未发送。"
        case .dispatching:
            "正在提交，等待 BOSS 确认；不会自动重试。"
        case .requestCreatedAwaitingRecruiter:
            "请求已创建，等待招聘方确认。"
        case .serverAcceptedUnverified:
            "BOSS 已接受发送，等待核实送达。"
        case .confirmed:
            "BOSS 历史已确认送达。"
        case .failed:
            "发送失败，已停止。"
        case .cancelled:
            "已取消发送。"
        }
    }

    private var exchangeKindTitle: String {
        switch record.exchangeKind {
        case .requestRecruiterConfirmation: "文字同意·需平台二次确认"
        case .acceptNativeRequest: "BOSS 原生索要简历卡片"
        }
    }

    private var activityTimeline: String {
        var values = [
            "创建 \(record.createdAt.formatted(date: .abbreviated, time: .shortened))",
            "更新 \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if let verifiedAt = record.verifiedAt {
            values.append("回读 \(verifiedAt.formatted(date: .omitted, time: .shortened))")
        }
        return values.joined(separator: " · ")
    }

    private var failureReason: String {
        switch record.failureCode {
        case .attachmentPreparationFailed: "无法生成可发送的 PDF 附件。"
        case .attachmentUploadFailed: "BOSS 附件上传或绑定失败。"
        case .authenticationRequired: "BOSS 账号登录已失效，需要重新登录。"
        case .requestRejected: "BOSS 拒绝了本次附件简历请求。"
        case .requestOutcomeUnknown: "请求结果无法确定；为避免重复投递，没有自动重试。"
        case .invalidResponse: "BOSS 返回的数据无法完成安全验证。"
        case .verificationFailed: "BOSS 接受操作后，完整历史未回读到可确认的投递结果。"
        case .cancelled: "投递操作已取消。"
        case .unknown: "发生未分类错误，没有自动重试。"
        case nil: "未保存明确的失败分类。"
        }
    }

    private var systemImage: String {
        switch record.state {
        case .queued: "clock"
        case .preparingAttachment: "doc.badge.gearshape"
        case .dispatching: "arrow.up.circle.fill"
        case .requestCreatedAwaitingRecruiter: "person.crop.circle.badge.clock"
        case .serverAcceptedUnverified: "checkmark.circle.badge.questionmark"
        case .confirmed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch record.state {
        case .queued, .cancelled: .secondary
        case .preparingAttachment, .dispatching: BossPilotTheme.accent
        case .requestCreatedAwaitingRecruiter, .serverAcceptedUnverified: .orange
        case .confirmed: .green
        case .failed: .red
        }
    }
}
