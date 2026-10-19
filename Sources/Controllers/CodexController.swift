import Foundation
import AppKit

@MainActor
final class CodexController: ObservableObject {
    private struct AssessmentInvocation {
        let token: UUID
        let accountID: UUID
        let task: Task<JobAssessment, Error>
    }

    private struct DraftInvocation {
        let token: UUID
        let accountID: UUID
        let task: Task<CodexReplyDraft, Error>
    }

    @Published private(set) var models: [CodexModelOption] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelListError: String?
    @Published private(set) var health: CodexCLIHealth?
    @Published private(set) var isChecking = false
    @Published private(set) var isProfilingResume = false
    @Published private(set) var resumeAnalysisStartedAt: Date?
    @Published private(set) var resumeAnalysisError: String?
    private var resumeAnalysisTask: Task<ResumeIntelligence, Error>?
    @Published private(set) var isPlanningSearch = false
    @Published private(set) var assessingJobIDs: Set<String> = []
    @Published private(set) var draftingConversationIDs: Set<String> = []

    @Published private(set) var isAuthorized = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isRevokingAuthorization = false
    @Published private(set) var authorizationURL: URL?
    private var authorizationTask: Task<Void, Never>?
    private var authorizationRevision = 0
    private let service: CodexCLIService
    private var assessmentInvocations: [String: AssessmentInvocation] = [:]
    private var draftInvocations: [String: DraftInvocation] = [:]
    private var resumeAnalysisRevision = 0
    private var searchPlanRevision = 0

    init(service: CodexCLIService = CodexCLIService()) {
        self.service = service
    }

    func analyzeResume(using store: AppStore) async {
        guard !Task.isCancelled else { return }
        resumeAnalysisRevision += 1
        let revision = resumeAnalysisRevision
        // shortcut: 最新请求每 50 毫秒等待旧任务结束；争用增加时改为 continuation 通知。
        while isProfilingResume {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard revision == resumeAnalysisRevision else { return }
        }
        guard !Task.isCancelled, revision == resumeAnalysisRevision else { return }
        let resume = store.snapshot.resume
        guard resume.hasStoredAttachment, resume.isReady else {
            store.report(CodexCLIError.invalidOutput("请先导入可读取的简历附件"))
            return
        }
        let generated = await updateResumeProfile(resume, using: store)
        if generated, !Task.isCancelled, revision == resumeAnalysisRevision,
           store.snapshot.preferences.hasSearchCriteria {
            await planSearch(using: store)
        }
    }

    func cancelResumeAnalysis() {
        resumeAnalysisRevision += 1
        resumeAnalysisTask?.cancel()
    }

    private func updateResumeProfile(_ resume: ResumeProfile, using store: AppStore) async -> Bool {
        isProfilingResume = true
        resumeAnalysisStartedAt = Date()
        resumeAnalysisError = nil
        defer {
            resumeAnalysisTask = nil
            resumeAnalysisStartedAt = nil
            isProfilingResume = false
        }
        let configuration = store.snapshot.codex
        let invocation = Task {
            try await service.profileResume(
                resumeText: resume.text,
                configuredPath: configuration.executablePath,
                model: configuration.model,
                reasoningEffort: configuration.reasoningEffort,
                timeoutSeconds: configuration.timeoutSeconds
            )
        }
        resumeAnalysisTask = invocation
        do {
            let intelligence = try await withTaskCancellationHandler {
                try await invocation.value
            } onCancel: {
                invocation.cancel()
            }
            guard !Task.isCancelled, !invocation.isCancelled,
                  store.snapshot.resume == resume else { return false }
            store.applyResumeIntelligence(intelligence, expectedResumeID: resume.id)
            store.addActivity(level: .success, title: "候选人画像已生成",
                              detail: "已从附件简历更新画像与检索方向。")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, !invocation.isCancelled,
                  store.snapshot.resume == resume else { return false }
            switch error {
            case CodexCLIError.busy: resumeAnalysisError = "Codex 正忙，请稍后重试。"
            case CodexCLIError.authorizationRequired: resumeAnalysisError = "请先在系统设置 → 智能引擎中授权。"
            case CodexCLIError.timedOut: resumeAnalysisError = "生成超时，请重试。"
            default: resumeAnalysisError = "生成失败，请重试。"
            }
            if !resume.hasGeneratedProfile, case CodexCLIError.busy = error {
                return false
            }
            if !resume.hasGeneratedProfile {
                let fallback = JobSearchPlanningPolicy.fallbackResumeIntelligence(resume: resume)
                store.applyResumeIntelligence(fallback, expectedResumeID: resume.id)
            }
            store.addActivity(level: .warning, title: "Codex 画像生成未完成", detail: error.localizedDescription)
            return false
        }
    }

    func planSearch(using store: AppStore) async {
        guard !Task.isCancelled else { return }
        searchPlanRevision += 1
        let revision = searchPlanRevision
        while isPlanningSearch {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard revision == searchPlanRevision else { return }
        }
        guard !Task.isCancelled, revision == searchPlanRevision else { return }
        isPlanningSearch = true
        defer { isPlanningSearch = false }
        let resume = store.snapshot.resume
        let requirementText = store.snapshot.preferences.requirementText
        guard resume.hasStoredAttachment,
              !requirementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let plan = try await service.planSearch(
                profileSummary: resume.profileSummary,
                fallbackQueries: resume.suggestedSearchQueries,
                requirementText: requirementText,
                configuredPath: store.snapshot.codex.executablePath,
                model: store.snapshot.codex.model,
                reasoningEffort: store.snapshot.codex.reasoningEffort,
                timeoutSeconds: store.snapshot.codex.timeoutSeconds
            )
            if store.snapshot.resume == resume,
               store.snapshot.preferences.requirementText == requirementText {
                store.applySearchPlan(plan, requirementText: requirementText, resumeID: resume.id)
            }
        } catch is CancellationError {
            return
        } catch {
            let fallback = JobSearchPlanningPolicy.fallbackSearchPlan(
                resume: resume,
                requirementText: requirementText
            )
            if store.snapshot.resume == resume,
               store.snapshot.preferences.requirementText == requirementText {
                store.applySearchPlan(fallback, requirementText: requirementText, resumeID: resume.id)
                store.addActivity(
                    level: .warning,
                    title: "检索计划使用本地回退",
                    detail: "Codex 暂时不可用，已从简历画像和自然语言要求生成本地检索计划。"
                )
            }
        }
    }

    func loadModels(using store: AppStore, refresh: Bool = false) async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelListError = nil
        let revision = authorizationRevision
        defer { isLoadingModels = false }
        do {
            let options = try await service.models(configuredPath: store.snapshot.codex.executablePath, refresh: refresh)
            guard revision == authorizationRevision else { return }
            models = options
        } catch is CancellationError {
            return
        } catch {
            guard revision == authorizationRevision else { return }
            modelListError = "模型列表暂不可用，请重试。"
        }
    }

    func check(using store: AppStore) async {
        guard !isChecking else { return }
        let revision = authorizationRevision
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await service.health(configuredPath: store.snapshot.codex.executablePath)
            let authorized = try await service.isAuthorized(configuredPath: store.snapshot.codex.executablePath)
            guard revision == authorizationRevision else { return }
            health = result
            isAuthorized = authorized
        } catch {
            guard revision == authorizationRevision else { return }
            health = nil
            isAuthorized = false
            store.report(error)
        }
    }

    func authorize(using store: AppStore) {
        guard !isAuthorizing, !isRevokingAuthorization else { return }
        authorizationRevision += 1
        let revision = authorizationRevision
        isAuthorizing = true
        authorizationURL = nil
        authorizationTask = Task {
            defer { isAuthorizing = false; authorizationURL = nil; authorizationTask = nil }
            do {
                try await service.authorize(configuredPath: store.snapshot.codex.executablePath) { [self] url in
                    await MainActor.run { [self] in
                        guard revision == self.authorizationRevision else { return }
                        self.authorizationURL = url
                        NSWorkspace.shared.open(url)
                    }
                }
                guard revision == authorizationRevision, !Task.isCancelled else { return }
                await check(using: store)
                await loadModels(using: store, refresh: true)
            } catch is CancellationError {
                return
            } catch {
                guard revision == authorizationRevision else { return }
                store.report(error)
            }
        }
    }

    func revokeAuthorization(using store: AppStore) async {
        guard !isRevokingAuthorization else { return }
        isRevokingAuthorization = true
        defer { isRevokingAuthorization = false }
        authorizationRevision += 1
        authorizationTask?.cancel()
        authorizationURL = nil
        models = []
        modelListError = nil
        isAuthorized = false
        cancelResumeAnalysis()
        searchPlanRevision += 1
        assessmentInvocations.values.forEach { $0.task.cancel() }
        draftInvocations.values.forEach { $0.task.cancel() }
        do {
            try await service.revokeAuthorization(configuredPath: store.snapshot.codex.executablePath)
        } catch {
            store.report(error)
        }
    }

    func assess(
        jobID: String,
        accountID: UUID? = nil,
        using store: AppStore,
        isStillValid: @escaping () -> Bool = { true }
    ) async {
        guard store.snapshot.automation.allowsDrafting else {
            store.report(CodexCLIError.invalidOutput("当前为“仅提醒”模式"))
            return
        }
        guard store.snapshot.codex.enableJobAssessment else {
            store.report(CodexCLIError.invalidOutput("配置中已关闭 Codex 岗位匹配评估"))
            return
        }
        guard store.snapshot.codex.allowJobDataToCodex else {
            store.report(CodexCLIError.invalidOutput("请在系统设置 → 智能引擎中开启岗位匹配评估。"))
            return
        }
        guard let job = store.snapshot.jobs.first(where: { $0.id == jobID }) else { return }
        let contextAccountID = accountID ?? store.selectedAccountID
        guard contextAccountID == job.accountID else {
            store.report(CodexCLIError.invalidOutput("岗位不属于当前账号上下文"))
            return
        }
        guard let account = store.snapshot.accounts.first(where: {
            $0.id == job.accountID &&
            $0.status == .active &&
            $0.loginStatus == .loggedIn &&
            $0.remoteProfile?.remoteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            store.report(CodexCLIError.invalidOutput("岗位所属 BOSS 账号尚未完成身份校验"))
            return
        }
        let remoteIdentity = account.remoteProfile?.remoteID ?? ""
        let resume = store.snapshot.resume
        let preferences = store.snapshot.preferences
        guard assessmentInvocations[jobID] == nil else { return }
        assessingJobIDs.insert(jobID)
        let invocationToken = UUID()
        let service = service
        let task = Task {
            try await service.assess(
                job: job,
                resume: resume,
                preferences: preferences,
                configuredPath: store.snapshot.codex.executablePath,
                model: store.snapshot.codex.model,
                reasoningEffort: store.snapshot.codex.reasoningEffort,
                timeoutSeconds: store.snapshot.codex.timeoutSeconds
            )
        }
        assessmentInvocations[jobID] = AssessmentInvocation(
            token: invocationToken,
            accountID: job.accountID,
            task: task
        )
        defer {
            assessingJobIDs.remove(jobID)
            if assessmentInvocations[jobID]?.token == invocationToken {
                assessmentInvocations[jobID] = nil
            }
        }
        do {
            let assessment = try await task.value
            guard store.snapshot.jobs.first(where: { $0.id == jobID }) == job,
                  store.snapshot.resume == resume,
                  store.snapshot.preferences == preferences,
                  (accountID != nil || store.selectedAccountID == contextAccountID),
                  store.snapshot.accounts.contains(where: {
                      $0.id == job.accountID &&
                      $0.status == .active &&
                      $0.loginStatus == .loggedIn &&
                      $0.remoteProfile?.remoteID == remoteIdentity
                  }),
                  isStillValid() else {
                store.addActivity(accountID: job.accountID, level: .warning, title: "Codex 评估已丢弃", detail: "岗位、简历或偏好在评估期间已变更，请重新评估。")
                return
            }
            store.applyCodexAssessment(assessment, to: jobID)
        } catch is CancellationError {
            return
        } catch {
            guard !task.isCancelled else { return }
            guard isStillValid() else { return }
            store.report(error)
        }
    }

    func draftReply(conversationID: String, using store: AppStore) async {
        guard store.snapshot.automation.allowsDrafting else {
            store.report(CodexCLIError.invalidOutput("当前为“仅提醒”模式"))
            return
        }
        guard store.snapshot.codex.enableReplyDrafting else {
            store.report(CodexCLIError.invalidOutput("配置中已关闭 Codex 消息分析"))
            return
        }
        guard store.snapshot.automation.allowRecruiterTextToCodex else {
            store.report(CodexCLIError.invalidOutput("请在系统设置 → 智能引擎中允许发送招聘消息。"))
            return
        }
        guard store.snapshot.codex.allowJobDataToCodex else {
            store.report(CodexCLIError.invalidOutput("请在系统设置 → 智能引擎中开启招聘消息分析。"))
            return
        }
        guard let conversation = store.snapshot.conversations.first(where: { $0.id == conversationID }),
              let message = conversation.messages.last(where: { $0.direction == .incoming }) else { return }
        let selectedAccountID = store.selectedAccountID
        guard selectedAccountID == conversation.accountID else {
            store.report(CodexCLIError.invalidOutput("会话不属于当前账号上下文"))
            return
        }
        let inputMessageID = message.id
        let resume = store.snapshot.resume
        guard let account = store.snapshot.accounts.first(where: {
            $0.id == conversation.accountID && $0.status == .active && $0.loginStatus == .loggedIn
        }) else {
            store.report(CodexCLIError.invalidOutput("会话所属 BOSS 账号尚未登录"))
            return
        }
        let remoteIdentity = account.remoteProfile?.remoteID ?? ""
        guard draftInvocations[conversationID] == nil else { return }
        draftingConversationIDs.insert(conversationID)
        let invocationToken = UUID()
        let service = service
        let task = Task {
            try await service.draftReply(
                recruiterMessage: message.text,
                resume: resume,
                jobTitle: conversation.jobTitle,
                company: conversation.company,
                configuredPath: store.snapshot.codex.executablePath,
                model: store.snapshot.codex.model,
                reasoningEffort: store.snapshot.codex.reasoningEffort,
                timeoutSeconds: store.snapshot.codex.timeoutSeconds
            )
        }
        draftInvocations[conversationID] = DraftInvocation(
            token: invocationToken,
            accountID: conversation.accountID,
            task: task
        )
        defer {
            draftingConversationIDs.remove(conversationID)
            if draftInvocations[conversationID]?.token == invocationToken {
                draftInvocations[conversationID] = nil
            }
        }

        do {
            let draft = try await task.value
            guard let currentConversation = store.snapshot.conversations.first(where: { $0.id == conversationID }),
                  currentConversation.accountID == conversation.accountID,
                  currentConversation.messages.last(where: { $0.direction == .incoming })?.id == inputMessageID,
                  let currentMessage = currentConversation.messages.last(where: { $0.direction == .incoming }),
                  currentMessage.text == message.text,
                  currentConversation.jobTitle == conversation.jobTitle,
                  currentConversation.company == conversation.company,
                  store.selectedAccountID == selectedAccountID,
                  store.snapshot.resume == resume,
                  store.snapshot.accounts.contains(where: {
                      $0.id == conversation.accountID &&
                      $0.status == .active &&
                      $0.loginStatus == .loggedIn &&
                      $0.remoteProfile?.remoteID == remoteIdentity
                  }),
                  store.snapshot.automation.allowsDrafting,
                  store.snapshot.automation.allowRecruiterTextToCodex,
                  store.snapshot.codex.allowJobDataToCodex else {
                store.addActivity(accountID: conversation.accountID, level: .warning, title: "Codex 结果已丢弃", detail: "会话在分析期间已更新或删除，请重新分析最新消息。")
                return
            }
            let localDecision = ConversationPolicy.classify(currentMessage.text)
            if draft.intent == .rejected || localDecision.intent == .rejected {
                store.addActivity(accountID: conversation.accountID, level: .info, title: "Codex 判断为拒绝", detail: "按规则不生成回复草稿。")
                return
            }
            if draft.intent == .resumeAccepted && localDecision.intent != .resumeAccepted {
                store.addActivity(accountID: conversation.accountID, level: .warning, title: "沟通意愿信号未通过本地复核", detail: "不创建发送简历待办，请在官方页面人工确认。")
                return
            }
            if draft.intent == .resumeAccepted,
               draft.shouldCreateResumeTask,
               draft.confidence >= 0.90,
               localDecision.intent == .resumeAccepted,
               localDecision.shouldCreateResumeTask {
                store.createDraftAction(
                    accountID: conversation.accountID,
                    conversationID: conversation.id,
                    jobID: nil,
                    kind: .sendResume,
                    content: draft.reply,
                    reason: "Codex 识别到明确继续沟通或接收简历信号：\(draft.reason)。请在官方页面复核并手动发送。"
                )
            } else if !draft.reply.isEmpty {
                store.createDraftAction(
                    accountID: conversation.accountID,
                    conversationID: conversation.id,
                    jobID: nil,
                    kind: .sendMessage,
                    content: draft.reply,
                    reason: "Codex 草稿：\(draft.reason)。复制后在官方页面人工确认。"
                )
            }
            store.addActivity(accountID: conversation.accountID, level: .success, title: "Codex 回复分析完成", detail: "意图：\(draft.intent.title)，置信度：\(Int(draft.confidence * 100))%。")
        } catch is CancellationError {
            return
        } catch {
            guard !task.isCancelled else { return }
            store.report(error)
        }
    }

    func cancelOperations(accountID: UUID) {
        assessmentInvocations.values
            .filter { $0.accountID == accountID }
            .forEach { $0.task.cancel() }
        draftInvocations.values
            .filter { $0.accountID == accountID }
            .forEach { $0.task.cancel() }
    }

    func cancelOperationsAndWait(accountID: UUID) async {
        let assessments = assessmentInvocations.values.filter { $0.accountID == accountID }
        let drafts = draftInvocations.values.filter { $0.accountID == accountID }
        assessments.forEach { $0.task.cancel() }
        drafts.forEach { $0.task.cancel() }

        for invocation in assessments {
            _ = await invocation.task.result
        }
        for invocation in drafts {
            _ = await invocation.task.result
        }
    }
}
