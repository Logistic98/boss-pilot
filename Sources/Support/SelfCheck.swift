import WebKit
import Combine
import Foundation
import SwiftUI

enum SelfCheckError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

@MainActor
struct SelfCheck {
    static func run() throws -> [String] {
        var passed: [String] = []
        let metricPreviewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-MetricLayout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: metricPreviewDirectory) }
        try verifyMetricCardLayout(outputDirectory: metricPreviewDirectory)
        passed.append("account metric cards fill four columns or balanced two-column rows")
        for width in [700.0, 947, 948, 1_100, 1_500, 1_900] {
            for height in [500.0, 760, 1_080] {
                let layout = JobSetupLayout(viewport: CGSize(width: width, height: height))
                try verify(layout.contentWidth <= width - 48 && layout.contentWidth <= 1_480,
                           "求职偏好内容宽度溢出窗口")
                if let profileWidth = layout.profileColumnWidth {
                    try verify(profileWidth >= 360 && profileWidth <= 520 &&
                               layout.contentWidth - profileWidth - 18 >= 520,
                               "求职偏好双栏挤压编辑区域")
                } else {
                    try verify(width < 948, "求职偏好未在足够宽时使用双栏")
                }
                try verify((280...480).contains(layout.requirementEditorHeight) &&
                           (120...180).contains(layout.greetingEditorHeight),
                           "求职偏好编辑框高度超出可读范围")
            }
        }
        passed.append("preferences layout adapts columns and editors to viewport size")
        let emptySnapshot = AppSnapshot()
        try verify(emptySnapshot.accounts.isEmpty && emptySnapshot.jobs.isEmpty &&
                   emptySnapshot.conversations.isEmpty && emptySnapshot.resume.text.isEmpty &&
                   emptySnapshot.resume.profileSummary.isEmpty && emptySnapshot.resume.attachmentPath == nil &&
                   emptySnapshot.preferences.requirementText.isEmpty, "新安装包含预置个人资料或业务数据")
        passed.append("empty installation contains no personal data")
        try verify(BossIndustryResolver.displayText(for: "100020") == "互联网" &&
                   BossIndustryResolver.displayText(for: " 未知行业名称 ") == "未知行业名称" &&
                   BossIndustryResolver.displayText(for: "999999999") == "" &&
                   BossIndustryResolver.displayText(for: nil) == "", "行业编号未正确解析或被当成名称显示")
        let industryJobs = BossPayloadParser.jobs(from: ["jobList": [
            ["jobName": "Java", "brandName": "公司", "industry": 100020],
            ["jobName": "Python", "brandName": "公司", "industry": 100020,
             "brandComInfo": ["industryName": "在线旅游"]]
        ]])
        var legacyIndustryJob = JobListing(id: "industry-legacy", accountID: UUID(), title: "Java", company: "公司")
        legacyIndustryJob.industry = "100020"
        try verify(industryJobs.map(\.industry) == ["互联网", "在线旅游"] &&
                   legacyIndustryJob.displayIndustry == "互联网" && !legacyIndustryJob.evidenceText.contains("100020"),
                   "行业代码未在列表解析和历史记录显示中正确处理")
        passed.append("industry dictionary and legacy code display")
        try verifyBatchOperationsAndListCaches()
        passed.append("batch operations publish once and list caches invalidate correctly")
        try verifyResumeUpdateBatch()
        passed.append("resume and requirement updates publish once with large job lists")
        try verifyManualRequirementsSave()
        passed.append("explicit requirements save and discard preserve drafts on failure")
        try verifyBackgroundResponsiveness()
        passed.append("background assessment and import keep main actor responsive and discard stale results")
        try verifySentResumeJobClassification()
        passed.append("manual attachment exchange and refreshed job routes")
        passed.append("resume exchange timestamps preserve send time and reject view time")
        try verifyCampusRecruitmentExclusions()
        passed.append("campus and internship exclusions at assessment and send boundaries")
        try verifyGlobalAccountFilter()
        passed.append("global account multi-selection and default all")

        let reopenDelegate = AppDelegate()
        try verify(reopenDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false),
                   "主窗口尚未注册时未保留系统默认重开行为")
        var mainWindowRequests = 0
        reopenDelegate.openMainWindow = { mainWindowRequests += 1 }
        let handlesClosedWindow = reopenDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        let handlesOtherWindow = reopenDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        try verify(!handlesClosedWindow && !handlesOtherWindow && mainWindowRequests == 2,
                   "关闭主窗口或仅有其他窗口时未请求恢复主窗口")
        var settingsRequests = 0
        reopenDelegate.openSettings = { settingsRequests += 1 }
        reopenDelegate.showSystemSettings()
        try verify(mainWindowRequests == 3 && settingsRequests == 1,
                   "系统设置菜单未同时恢复主窗口并请求页面内导航")
        passed.append("main window reopen and inline system settings routing")

        try verify(
            ContentIssueRoute.resolve(
                message: "请在系统设置 → 智能引擎中允许发送岗位与画像。"
            ) == .configuration(section: "codex") &&
                ContentIssueRoute.resolve(message: "请先在设置的隐私页授权") == .configuration(section: "codex") &&
                ContentIssueRoute.resolve(message: "请在系统设置 → 智能引擎中允许发送招聘消息。") == .configuration(section: "codex") &&
                ContentIssueRoute.resolve(message: "请在系统设置 → 智能分析中授权") == .configuration(section: "codex"),
            "数据授权错误未路由到智能引擎设置"
        )
        try verify(SystemSettingsView.normalizedSection("privacy") == "codex" &&
                   SystemSettingsView.normalizedSection("codex") == "codex" &&
                   SystemSettingsView.normalizedSection("automation") == "automation" &&
                   SystemSettingsView.normalizedSection("unknown") == "automation",
                   "旧隐私类别或无效类别未迁移到有效设置页")
        try verify(
            ContentIssueRoute.resolve(message: "Codex 尚未授权，请先登录") == .configuration(section: "codex") &&
                ContentIssueRoute.resolve(message: "无法启动 Codex CLI") == .configuration(section: "codex"),
            "Codex 授权或 CLI 错误未路由到系统设置页"
        )
        try verify(
            ContentIssueRoute.resolve(message: "BOSS 账号会话已失效") == .sidebar(.accounts),
            "BOSS 会话错误未路由到账号管理"
        )
        try verify(
            ContentIssueRoute.resolve(message: "请先导入可读取的简历附件") == .sidebar(.setup),
            "简历错误未路由到求职偏好页"
        )
        passed.append("issue action routing")

        try verify(
            StableListSelectionPolicy.reconciledSelection(
                current: "current",
                preferred: "preferred",
                visibleIDs: ["current", "preferred"]
            ) == "current" &&
            StableListSelectionPolicy.reconciledSelection(
                current: "missing",
                preferred: "preferred",
                visibleIDs: ["first", "preferred"]
            ) == "preferred" &&
            StableListSelectionPolicy.reconciledSelection(
                current: "missing",
                preferred: "also-missing",
                visibleIDs: ["first", "second"]
            ) == "first" &&
            StableListSelectionPolicy.reconciledSelection(
                current: "missing",
                preferred: nil,
                visibleIDs: []
            ) == nil,
            "大列表选中项未在当前、外部偏好、首项和空列表之间稳定协调"
        )
        passed.append("stable list selection reconciliation")
        try verifyFriendSummaryBatch()
        passed.append("friend summary batch publication and account isolation")
        try verifyBackgroundPersistence()
        passed.append("background persistence ordering and durable ledger")
        try verifyResumeJavaScriptLifecycle()
        passed.append("resume JavaScript timeout and process recovery")

        let processLockRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-ProcessLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: processLockRoot) }
        let processLockURL = processLockRoot.appendingPathComponent("instance.lock")
        let processLock = try BossPilotProcessLock.acquire(fileURL: processLockURL)
        var rejectedSecondProcess = false
        do {
            _ = try BossPilotProcessLock.acquire(fileURL: processLockURL)
        } catch BossPilotProcessLockError.alreadyRunning {
            rejectedSecondProcess = true
        }
        let processLockPermissions = try FileManager.default
            .attributesOfItem(atPath: processLockURL.path)[.posixPermissions] as? NSNumber
        try verify(
            rejectedSecondProcess &&
            processLock.closesOnExec &&
            processLockPermissions?.intValue == 0o600,
            "单实例锁未拒绝第二持有者、未设置 close-on-exec 或权限不安全"
        )
        passed.append("single process state lock")

        let previewPolicyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-PreviewPolicy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: previewPolicyRoot) }
        let requestedPreviewStateURL = previewPolicyRoot
            .appendingPathComponent("fixture", isDirectory: true)
            .appendingPathComponent("preview-state.json")
        let previewMode = BossPilotLaunchMode.resolve(
            arguments: ["BossPilot", "--ui-preview"],
            environment: ["BOSSPILOT_PREVIEW_STATE_PATH": requestedPreviewStateURL.path],
            temporaryDirectory: previewPolicyRoot,
            processIdentifier: 42
        )
        let previewRuntime = try required(previewMode.previewRuntime, "UI Preview 未生成隔离运行配置")
        let liveMode = BossPilotLaunchMode.resolve(
            arguments: ["BossPilot"],
            environment: [:],
            temporaryDirectory: previewPolicyRoot,
            processIdentifier: 42
        )
        let escapedPreviewMode = BossPilotLaunchMode.resolve(
            arguments: ["BossPilot", "--ui-preview"],
            environment: [
                "BOSSPILOT_PREVIEW_STATE_PATH": previewPolicyRoot
                    .deletingLastPathComponent()
                    .appendingPathComponent("outside-state.json")
                    .path
            ],
            temporaryDirectory: previewPolicyRoot,
            processIdentifier: 42
        )
        let escapedRuntime = try required(
            escapedPreviewMode.previewRuntime,
            "UI Preview 非法状态路径未生成安全回退配置"
        )
        try verify(
            !previewMode.performsLiveRuntimeWork &&
            liveMode.performsLiveRuntimeWork &&
            liveMode.previewRuntime == nil &&
            previewRuntime.stateURL == requestedPreviewStateURL.resolvingSymlinksInPath().standardizedFileURL &&
            previewRuntime.processLockURL == previewRuntime.stateURL.appendingPathExtension("lock") &&
            previewRuntime.processLockURL != processLockURL &&
            escapedRuntime.stateURL == previewPolicyRoot
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .appendingPathComponent("BossPilot-UI-Preview-42", isDirectory: true)
                .appendingPathComponent("state.json"),
            "UI Preview 启动状态、隔离状态路径或锁路径策略不正确"
        )

        let previewLock = try BossPilotProcessLock.acquire(fileURL: previewRuntime.processLockURL)
        let independentLiveSimulationLock = try BossPilotProcessLock.acquire(
            fileURL: previewPolicyRoot.appendingPathComponent("live-simulation.instance.lock")
        )
        var rejectedSecondPreview = false
        do {
            _ = try BossPilotProcessLock.acquire(fileURL: previewRuntime.processLockURL)
        } catch BossPilotProcessLockError.alreadyRunning {
            rejectedSecondPreview = true
        }
        let previewPersistence = JSONStatePersistence(fileURL: previewRuntime.stateURL)
        var previewState = AppSnapshot()
        previewState.preferences.requirementText = "preview-isolated-state"
        try previewPersistence.save(previewState)
        let loadedPreviewState = try previewPersistence.load()
        try verify(
            rejectedSecondPreview &&
            previewLock.closesOnExec &&
            independentLiveSimulationLock.closesOnExec &&
            loadedPreviewState.preferences.requirementText == "preview-isolated-state" &&
            FileManager.default.fileExists(atPath: previewRuntime.stateURL.path),
            "UI Preview 独立锁未互斥、阻塞了正式锁或状态未落在预览路径"
        )
        passed.append("ui preview state and process isolation")

        let bossCookie = try required(
            HTTPCookie(properties: [
                .domain: ".zhipin.com",
                .path: "/",
                .name: "wt2",
                .value: "self-check"
            ]),
            "BOSS 登录 Cookie 样本创建失败"
        )
        let unrelatedCookie = try required(
            HTTPCookie(properties: [
                .domain: ".example.com",
                .path: "/",
                .name: "wt2",
                .value: "self-check"
            ]),
            "非 BOSS Cookie 样本创建失败"
        )
        let secureCookie = try required(
            HTTPCookie(properties: [
                .domain: ".zhipin.com",
                .path: "/",
                .name: "zp_at",
                .value: "self-check-zp-at",
                .secure: "TRUE",
                HTTPCookiePropertyKey("HttpOnly"): "TRUE"
            ]),
            "安全 Cookie 样本创建失败"
        )
        try verify(BossWebSessionService.isAuthenticated(cookies: [bossCookie, secureCookie]), "有效 BOSS 登录 Cookie 未识别")
        try verify(!BossWebSessionService.isAuthenticated(cookies: [bossCookie]), "缺少 zp_at 的 Cookie 被误判为完整登录")
        try verify(!BossWebSessionService.isAuthenticated(cookies: [unrelatedCookie, secureCookie]), "非 BOSS 域名 Cookie 被误判为登录")
        passed.append("boss login cookie detection")

        try verify(
            BossQRCodeScanDisplayPolicy.permitsDisplay(
                generation: 7,
                currentGeneration: 7,
                listenerGeneration: 7,
                state: .armed,
                isInvalidated: false
            ) &&
            BossQRCodeScanDisplayPolicy.permitsDisplay(
                generation: 7,
                currentGeneration: 7,
                listenerGeneration: 7,
                state: .completed,
                isInvalidated: false
            ) &&
            !BossQRCodeScanDisplayPolicy.permitsDisplay(
                generation: 7,
                currentGeneration: 7,
                listenerGeneration: 7,
                state: .failed,
                isInvalidated: false
            ) &&
            !BossQRCodeScanDisplayPolicy.permitsDisplay(
                generation: 7,
                currentGeneration: 8,
                listenerGeneration: 7,
                state: .completed,
                isInvalidated: false
            ),
            "BOSS 二维码监听门禁拒绝已正常完成的首轮未扫码请求，或允许旧 generation/失败请求显示二维码"
        )
        passed.append("boss qr listener display gate")

        let requestGate = BossRequestEpochGate()
        let firstAccount = UUID()
        let secondAccount = UUID()
        let firstToken = requestGate.token(accountID: firstAccount)
        let secondToken = requestGate.token(accountID: secondAccount)
        requestGate.invalidate(accountID: firstAccount)
        try verify(
            !requestGate.isCurrent(accountID: firstAccount, token: firstToken) &&
            requestGate.isCurrent(accountID: secondAccount, token: secondToken),
            "账号请求同步失效门禁未隔离或未生效"
        )
        passed.append("boss request cancellation gate")
        try verifyCodexStaleResults()
        passed.append("Codex delayed result invalidation and process cancellation")
        try verifyWebRequestIsolation()
        passed.append("WebKit request isolation, concurrency, timeout and recovery")
        try verifyAccountCancellation()
        passed.append("queued request cancellation and isolated account deletion")
        let credential = BossCredential(cookies: [bossCookie, secureCookie])
        let credentialRoundTrip = try JSONDecoder().decode(
            BossCredential.self,
            from: JSONEncoder().encode(credential)
        )
        try verify(
            credentialRoundTrip.hasIdentity &&
            credentialRoundTrip.httpCookies.first(where: { $0.name == "zp_at" })?.isSecure == true &&
            credentialRoundTrip.httpCookies.first(where: { $0.name == "zp_at" })?.isHTTPOnly == true &&
            credentialRoundTrip.httpCookies.allSatisfy {
                $0.domain == "zhipin.com" || $0.domain.hasSuffix(".zhipin.com")
            },
            "Cookie DTO 往返丢失身份或安全属性"
        )
        passed.append("boss credential encoding")

        let credentialVaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-CredentialVault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: credentialVaultRoot) }
        let credentialVault = BossCredentialVault(directoryURL: credentialVaultRoot)
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        try credentialVault.save(credential, profileID: firstProfileID)
        let restoredCredential = try credentialVault.load(profileID: firstProfileID)
        let unrelatedStoredCredential = try credentialVault.load(profileID: secondProfileID)
        let credentialFilePermissions = try credentialVault.filePermissions(profileID: firstProfileID)
        let credentialDirectoryPermissions = try FileManager.default
            .attributesOfItem(atPath: credentialVaultRoot.path)[.posixPermissions] as? NSNumber
        try verify(
            restoredCredential?.hasIdentity == true &&
            unrelatedStoredCredential == nil &&
            credentialFilePermissions == 0o600 &&
            credentialDirectoryPermissions?.intValue == 0o700,
            "按账号隔离的本地会话文件无法安全往返，或权限不正确"
        )
        try credentialVault.remove(profileID: firstProfileID)
        let removedStoredCredential = try credentialVault.load(profileID: firstProfileID)
        try verify(
            removedStoredCredential == nil,
            "退出后本地 BOSS 会话文件未删除"
        )
        passed.append("boss credential file persistence")

        let filteredCredential = BossCredential(cookies: [bossCookie, secureCookie, unrelatedCookie])
        try verify(
            filteredCredential.hasIdentity &&
            filteredCredential.httpCookies.count == 2 &&
            filteredCredential.httpCookies.allSatisfy {
                $0.domain == "zhipin.com" || $0.domain.hasSuffix(".zhipin.com")
            },
            "持久 WebKit 会话未隔离非 BOSS 域 Cookie"
        )
        passed.append("boss credential domain filtering")

        let stokenCookie = try required(
            HTTPCookie(properties: [
                .domain: ".zhipin.com", .path: "/", .name: "__zp_stoken__", .value: "self-check-stoken"
            ]),
            "BOSS stoken Cookie 样本创建失败"
        )
        let wbgCookie = try required(
            HTTPCookie(properties: [
                .domain: ".zhipin.com", .path: "/", .name: "wbg", .value: "self-check-wbg"
            ]),
            "BOSS wbg Cookie 样本创建失败"
        )
        let automationCredential = BossCredential(cookies: [bossCookie, secureCookie, stokenCookie, wbgCookie])
        try verify(
            automationCredential.isAutomationReady &&
            automationCredential.hasIdentity &&
            Set(automationCredential.connectorCookies.map(\.name)).isSuperset(
                of: BossCredential.automationCookieNames
            ),
            "BOSS 官方动态 Cookie 未作为同一 WebKit 身份完整保留"
        )
        let incompleteAutomationCredential = BossCredential(cookies: [bossCookie, secureCookie, stokenCookie])
        try verify(
            incompleteAutomationCredential.isAutomationReady,
            "已验证的 WebKit 会话缺少可选 wbg 时不应阻断同源协议请求"
        )
        try verify(
            !BossCredential(cookies: [bossCookie, secureCookie]).isAutomationReady,
            "缺少 __zp_stoken__ 的 BOSS 会话被误判为可执行协议请求"
        )
        try verify(
            BossBrowserIdentity.userAgent.contains("Safari/") &&
            !BossBrowserIdentity.userAgent.contains("Chrome/"),
            "QR 与隐藏 WebKit 仍混用了 Chrome/Safari 浏览器指纹"
        )
        passed.append("boss browser identity and cookie continuity")

        let idleReplacement = BossCredentialReplacementState.idle
        let activeReplacement = idleReplacement.applying(.begin)
        let completedReplacement = activeReplacement.applying(.finish)
        try verify(
            idleReplacement.allowsWarmupWebView &&
            !idleReplacement.isInProgress &&
            activeReplacement.isInProgress &&
            !activeReplacement.allowsWarmupWebView &&
            completedReplacement == .idle &&
            completedReplacement.allowsWarmupWebView,
            "Cookie replacement 期间未关闭隐藏预热 WebView，或完成后未恢复"
        )
        passed.append("boss credential replacement warm-up gate")

        let legacyAccountID = UUID()
        let legacyAccountData = Data("{\"id\":\"\(legacyAccountID.uuidString)\",\"displayName\":\"旧账号\"}".utf8)
        let legacyAccount = try JSONDecoder().decode(BossAccount.self, from: legacyAccountData)
        try verify(
            legacyAccount.webProfileID == legacyAccountID && legacyAccount.loginStatus == .loggedOut && legacyAccount.customName == nil,
            "旧账号未迁移到独立 WebKit Profile"
        )
        passed.append("account web profile migration")
        try verifyAccountRenaming()
        passed.append("account rename persistence and profile refresh isolation")

        try verify(
            JobMatchingPolicy.salaryRange(from: "20-30K") == .init(minimumK: 20, maximumK: 30) &&
            JobMatchingPolicy.salaryRange(from: "月薪 35K 以上") == .init(minimumK: 35, maximumK: 35) &&
            JobMatchingPolicy.salaryRange(from: "3.5 万起") == .init(minimumK: 35, maximumK: 35),
            "薪资解析失败"
        )
        passed.append("salary parsing")

        let naturalPlanResume = ResumeProfile(
            text: "5 年 Java Spring Boot 微服务开发经验",
            skills: ["Java", "Spring Boot"],
            yearsOfExperience: 5,
            profileSummary: "5 年 Java 后端与微服务开发经验。",
            suggestedSearchQueries: ["Java 开发工程师"]
        )
        let naturalPlan = JobSearchPlanningPolicy.fallbackSearchPlan(
            resume: naturalPlanResume,
            requirementText: "寻找上海的 Java 后端工程师，必须 Kubernetes，不考虑外包。"
        )
        try verify(
            naturalPlan.queries.contains(where: { $0.localizedCaseInsensitiveContains("Java") }) &&
            naturalPlan.cities == ["上海"] &&
            JobSearchPlanningPolicy.explicitRequiredTerms(
                in: "必须有微服务和 Kubernetes 实战，不考虑外包"
            ) == ["微服务", "Kubernetes"] &&
            JobSearchPlanningPolicy.explicitRequiredTerms(
                in: "只考虑上海，其他城市的不考虑，这条是严格排除。"
            ) == ["上海"] &&
            JobSearchPlanningPolicy.explicitRequiredTerms(
                in: "必须Java，Python，不考虑外包。"
            ) == ["Java", "Python"] &&
            JobSearchPlanningPolicy.explicitExcludedTerms(
                in: "必须有微服务和 Kubernetes 实战，不考虑外包、驻场"
            ) == ["外包", "驻场"] &&
            JobSearchPlanningPolicy.explicitExcludedTerms(
                in: "若是偏销售的不考虑。屏蔽示例甲科技、外包、OD、劳务派遣。不考0-20人的公司。"
            ) == ["偏销售", "示例甲科技", "外包", "OD", "劳务派遣", "0-20人"] &&
            JobSearchPlanningPolicy.explicitPreferredTerms(
                in: "更看重技术深度与业务复杂度"
            ) == ["技术深度", "业务复杂度"],
            "自然语言求职要求未生成稳定检索计划"
        )
        passed.append("natural language search planning")

        let repairedPlan = JobSearchPlanningPolicy.normalizedSearchPlan(
            queries: [" Agent研发工程师\n", "AI应用研发工程师"],
            requirementText: "上海优先，其次杭州、苏州、南京，其他城市不考虑。",
            provider: "Codex CLI"
        )
        try verify(
            repairedPlan.queries == ["Agent研发工程师", "AI应用研发工程师"] &&
            repairedPlan.cities == ["上海", "杭州", "苏州", "南京"] &&
            !repairedPlan.cities.contains("南京前端开发"),
            "Codex 检索计划中的非法城市未在持久化前从自然语言要求重建"
        )
        passed.append("search plan parameter normalization")

        let validCodexOutput = Data("{\"result\":\"ok\"}".utf8)
        let validatedCodexOutput = try CodexCLIOutputPolicy.validatedOutput(
            terminationStatus: 0,
            output: validCodexOutput,
            stderr: Data()
        )
        try verify(
            validatedCodexOutput == validCodexOutput,
            "Codex CLI 有效 JSON 对象输出未被接受"
        )

        for missingOutput in [nil, Data(), Data("  \n\t  ".utf8)] as [Data?] {
            var rejectedMissingOutput = false
            do {
                _ = try CodexCLIOutputPolicy.validatedOutput(
                    terminationStatus: 0,
                    output: missingOutput,
                    stderr: Data()
                )
            } catch CodexCLIError.missingOutput {
                rejectedMissingOutput = true
            }
            try verify(
                rejectedMissingOutput,
                "Codex CLI 成功退出后的缺失、空或纯空白输出未报 missingOutput"
            )
        }

        var rejectedInvalidCodexOutput = false
        do {
            _ = try CodexCLIOutputPolicy.validatedOutput(
                terminationStatus: 0,
                output: Data("not-json".utf8),
                stderr: Data()
            )
        } catch CodexCLIError.invalidOutput {
            rejectedInvalidCodexOutput = true
        }
        try verify(
            rejectedInvalidCodexOutput,
            "Codex CLI 成功退出后的非 JSON 输出未报 invalidOutput"
        )

        var preservedCodexFailure = false
        do {
            _ = try CodexCLIOutputPolicy.validatedOutput(
                terminationStatus: 17,
                output: validCodexOutput,
                stderr: Data(" synthetic failure \n".utf8)
            )
        } catch CodexCLIError.failed(let status, let message) {
            preservedCodexFailure = status == 17 && message == "synthetic failure"
        }
        try verify(
            preservedCodexFailure,
            "Codex CLI 非零退出码或错误摘要未保留"
        )
        passed.append("codex cli output and exit policy")

        let searchDescriptor = BossSearchRequestDescriptor(
            query: "  Agent研发工程师\n  ",
            cityCode: "101020100",
            page: 8
        )
        let searchParameters = Dictionary(
            uniqueKeysWithValues: searchDescriptor.formItems.compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        try verify(
            searchDescriptor.method == .POST &&
            BossSearchRequestDescriptor.path == "/wapi/zpgeek/search/joblist.json" &&
            searchDescriptor.queryItems.isEmpty &&
            searchParameters == [
                "query": "Agent研发工程师",
                "city": "101020100",
                "page": "8",
                "pageSize": "15"
            ] && searchDescriptor.referer.contains("query=Agent"),
            "BOSS 岗位检索请求未生成官方 POST form 合约"
        )
        passed.append("boss search request descriptor")

        let greetDescriptor = try BossGreetRequestDescriptor(
            securityID: "selfcheck-security",
            jobID: "selfcheck-job",
            listID: "selfcheck-lid"
        )
        let greetParameters = Dictionary(
            uniqueKeysWithValues: greetDescriptor.queryItems.map { ($0.name, $0.value ?? "") }
        )
        let friendDescriptor = try BossFriendListRequestDescriptor(
            friendIDs: ["friend-a", "friend-a"],
            directFriendIDs: ["friend-b"]
        )
        let friendParameters = Dictionary(
            uniqueKeysWithValues: friendDescriptor.formItems.map { ($0.name, $0.value ?? "") }
        )
        var rejectedEmptyFriendEnumeration = false
        do {
            _ = try BossFriendListRequestDescriptor(friendIDs: [], directFriendIDs: [])
        } catch BossAPIError.unsupported {
            rejectedEmptyFriendEnumeration = true
        }
        try verify(
            greetDescriptor.method == .POST &&
            BossGreetRequestDescriptor.path == "/wapi/zpgeek/friend/add.json" &&
            greetDescriptor.formItems.isEmpty &&
            greetParameters == [
                "securityId": "selfcheck-security",
                "jobId": "selfcheck-job",
                "lid": "selfcheck-lid"
            ] &&
            friendDescriptor.method == .POST &&
            BossFriendListRequestDescriptor.path == "/wapi/zprelation/friend/getGeekFriendList.json" &&
            friendParameters == [
                "friendIds": "friend-a",
                "dzFriendIds": "friend-b"
            ] &&
            rejectedEmptyFriendEnumeration,
            "BOSS 开聊缺少 jobId/lid，或 friend-list 仍允许空参数枚举"
        )
        passed.append("boss greet and known-friend protocol descriptors")

        let paginationAccountA = try required(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001"),
            "无法生成分页账号 A"
        )
        let paginationAccountB = try required(
            UUID(uuidString: "10000000-0000-0000-0000-000000000002"),
            "无法生成分页账号 B"
        )
        let paginationResumeID = try required(
            UUID(uuidString: "20000000-0000-0000-0000-000000000001"),
            "无法生成分页简历 ID"
        )
        let paginationTargets = [
            BossJobSearchTarget(query: "  Agent研发工程师\n", city: "上海", cityCode: "101020100"),
            BossJobSearchTarget(query: "AI应用研发工程师", city: "杭州", cityCode: "101210100")
        ]
        let paginationPlan = BossJobSearchPaginationPolicy.planFingerprint(
            remoteIdentityID: "pagination-identity-a",
            resumeID: paginationResumeID,
            requirementText: "上海优先，必须有 Agent 经验",
            targets: paginationTargets
        )
        let equivalentPaginationPlan = BossJobSearchPaginationPolicy.planFingerprint(
            remoteIdentityID: "pagination-identity-a",
            resumeID: paginationResumeID,
            requirementText: "  上海优先，必须有   Agent 经验  ",
            targets: Array(paginationTargets.reversed())
        )
        let changedPaginationPlan = BossJobSearchPaginationPolicy.planFingerprint(
            remoteIdentityID: "pagination-identity-a",
            resumeID: paginationResumeID,
            requirementText: "杭州优先，必须有 Agent 经验",
            targets: paginationTargets
        )
        let changedPaginationIdentityPlan = BossJobSearchPaginationPolicy.planFingerprint(
            remoteIdentityID: "pagination-identity-b",
            resumeID: paginationResumeID,
            requirementText: "上海优先，必须有 Agent 经验",
            targets: paginationTargets
        )
        let changedPaginationResumePlan = BossJobSearchPaginationPolicy.planFingerprint(
            remoteIdentityID: "pagination-identity-a",
            resumeID: try required(
                UUID(uuidString: "20000000-0000-0000-0000-000000000002"),
                "无法生成变更后的分页简历 ID"
            ),
            requirementText: "上海优先，必须有 Agent 经验",
            targets: paginationTargets
        )
        var paginationSettings = AutomationSettings()
        let firstPage = paginationSettings.nextJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: paginationPlan
        )
        paginationSettings.recordCompletedJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: paginationPlan,
            completedPage: firstPage,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let persistedPaginationSettings = try JSONDecoder().decode(
            AutomationSettings.self,
            from: JSONEncoder().encode(paginationSettings)
        )
        let secondPage = persistedPaginationSettings.nextJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: paginationPlan
        )
        let repeatedReadWithoutCompletion = persistedPaginationSettings.nextJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: paginationPlan
        )
        var wrappedPaginationSettings = persistedPaginationSettings
        wrappedPaginationSettings.recordCompletedJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: paginationPlan,
            completedPage: BossJobSearchPaginationPolicy.supportedPages.upperBound,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let wrappedPage = wrappedPaginationSettings.nextJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: paginationPlan
        )
        wrappedPaginationSettings.recordCompletedJobSearchPage(
            accountID: paginationAccountA,
            planFingerprint: changedPaginationPlan,
            completedPage: 1,
            now: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try verify(
            paginationPlan == equivalentPaginationPlan &&
            paginationPlan != changedPaginationPlan &&
            paginationPlan != changedPaginationIdentityPlan &&
            paginationPlan != changedPaginationResumePlan &&
            firstPage == 1 &&
            secondPage == 2 &&
            repeatedReadWithoutCompletion == 2 &&
            persistedPaginationSettings.lastCompletedJobSearchAt(
                accountID: paginationAccountA,
                planFingerprint: paginationPlan
            ) == Date(timeIntervalSince1970: 1_700_000_000) &&
            persistedPaginationSettings.lastCompletedJobSearchAt(
                accountID: paginationAccountA,
                planFingerprint: changedPaginationPlan
            ) == nil &&
            persistedPaginationSettings.nextJobSearchPage(
                accountID: paginationAccountB,
                planFingerprint: paginationPlan
            ) == 1 &&
            persistedPaginationSettings.nextJobSearchPage(
                accountID: paginationAccountA,
                planFingerprint: changedPaginationPlan
            ) == 1 &&
            wrappedPage == 1 &&
            wrappedPaginationSettings.nextJobSearchPage(
                accountID: paginationAccountA,
                planFingerprint: paginationPlan
            ) == 1 &&
            wrappedPaginationSettings.nextJobSearchPage(
                accountID: paginationAccountA,
                planFingerprint: changedPaginationPlan
            ) == 2 &&
            wrappedPaginationSettings.jobSearchPaginationStates.count == 1,
            "BOSS 岗位分页未按账号与检索计划持久、失败时跳页，或未在支持页范围内公平轮转"
        )
        passed.append("boss search pagination persistence and isolation")

        let contextualError = BossAPIError.upstream(
            operation: .accountExpectations,
            code: 19,
            message: "参数值错误"
        )
        try verify(
            contextualError.localizedDescription.contains("求职期望") &&
            contextualError.localizedDescription.contains("19"),
            "BOSS 上游错误丢失了安全的操作上下文"
        )
        passed.append("boss upstream error context")

        let manualVerificationFailures = [32, 35, 36, 121, 122].map { code in
            BossServerFailurePolicy.error(
                operation: .searchJobs,
                code: code,
                message: "需要安全验证"
            )
        }
        let manualVerificationErrorsAreClassified = manualVerificationFailures.allSatisfy { error in
            if case .manualVerificationRequired = error { return true }
            return false
        }
        let ordinaryFrequencyError = BossServerFailurePolicy.error(
            operation: .searchJobs,
            code: 9,
            message: "您的操作过于频繁，请稍后再试"
        )
        let staleConnectorSession = BossServerFailurePolicy.error(
            operation: .greet,
            code: 1011,
            message: "当前登录状态已失效"
        )
        let ordinaryFrequencyClassified: Bool
        if case .upstream = ordinaryFrequencyError {
            ordinaryFrequencyClassified = true
        } else {
            ordinaryFrequencyClassified = false
        }
        let staleConnectorSessionRefreshes: Bool
        if case .webTokenExpired = staleConnectorSession {
            staleConnectorSessionRefreshes = true
        } else {
            staleConnectorSessionRefreshes = false
        }
        let directHTTP429 = BossAPIError.httpStatus(429)
        let directHTTP429Classified: Bool
        if case .httpStatus(429) = directHTTP429 {
            directHTTP429Classified = true
        } else {
            directHTTP429Classified = false
        }
        try verify(
            manualVerificationErrorsAreClassified &&
            ordinaryFrequencyClassified &&
            directHTTP429Classified &&
            BossAutomationController.safetyCooldownSeconds(for: ordinaryFrequencyError) == 24 * 60 * 60 &&
            BossAutomationController.safetyCooldownSeconds(for: directHTTP429) == 24 * 60 * 60 &&
            BossAutomationController.safetyCooldownSeconds(for: BossResumeExchangeError.httpStatus(
                endpoint: "/history", status: 429, writeMayHaveCommitted: false
            )) == 24 * 60 * 60 &&
            BossAutomationController.safetyCooldownSeconds(for: BossResumeExchangeError.httpStatus(
                endpoint: "/resume", status: 403, writeMayHaveCommitted: true
            )) == 24 * 60 * 60 &&
            BossAutomationController.safetyCooldownSeconds(for: BossResumeExchangeError.APIError(
                endpoint: "/resume", code: 9, writeMayHaveCommitted: true
            )) == 24 * 60 * 60 &&
            BossAutomationController.safetyCooldownSeconds(for: BossResumeExchangeError.APIError(
                endpoint: "/resume", code: 1, writeMayHaveCommitted: false
            )) == nil &&
            BossAutomationController.safetyCooldownSeconds(for: BossAPIError.upstream(
                operation: .greet, code: 1, message: "开聊提醒"
            )) == nil &&
            BossAutomationController.safetyCooldownSeconds(for: BossAPIError.upstream(
                operation: .greet, code: 1, message: "请求频繁"
            )) == 24 * 60 * 60 &&
            BossAutomationController.safetyCooldownSeconds(for: staleConnectorSession) == nil &&
            staleConnectorSessionRefreshes,
            "BOSS 人工验证错误分类、频率错误冷却或 1011 网页会话刷新策略不正确"
        )
        passed.append("boss manual verification and risk backoff policy")

        let requestScopedFailures: [Error] = [
            BossAPIError.invalidPayload(BossWebAPIError.pageLoadTimedOut.localizedDescription),
            BossAPIError.invalidPayload(BossWebAPIError.invalidBridgeResponse.localizedDescription),
            BossAPIError.invalidPayload("BOSS 岗位列表缺少薪资证据"),
            BossAPIError.httpStatus(500),
            BossAPIError.httpStatus(502),
            BossAPIError.httpStatus(408),
            BossAPIError.upstream(operation: .searchJobs, code: 1, message: "服务异常，请稍后再试"),
            BossAPIError.upstream(operation: .greet, code: 1, message: "Too many attachments"),
            BossWebAPIError.pageLoadTimedOut,
            BossWebAPIError.requestInProgress,
            BossResumeExchangeError.navigationTimedOut,
            BossResumeExchangeError.httpStatus(endpoint: "/history", status: 503, writeMayHaveCommitted: false),
            URLError(.timedOut),
            CancellationError(),
            NSError(domain: "SelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "请稍后再试"])
        ]
        try verify(
            requestScopedFailures.allSatisfy { BossAutomationController.safetyCooldownSeconds(for: $0) == nil },
            "普通超时、数据异常、服务故障或稍后再试被误判为全局风控冷却"
        )
        let explicitRiskFailures: [Error] = [
            BossAPIError.httpStatus(403),
            BossAPIError.manualVerificationRequired(operation: .searchJobs, code: 36, message: "需要安全验证"),
            BossResumeExchangeError.APIError(endpoint: "/history", code: 36, writeMayHaveCommitted: false),
            BossAPIError.upstream(operation: .greet, code: 1, message: "账号已封禁"),
            BossAPIError.upstream(operation: .searchJobs, code: 1, message: "请求已限流"),
            BossAPIError.upstream(operation: .searchJobs, code: 1, message: "Too Many Requests"),
            BossAPIError.upstream(operation: .searchJobs, code: 1, message: "Rate limit exceeded")
        ]
        try verify(
            explicitRiskFailures.allSatisfy { BossAutomationController.safetyCooldownSeconds(for: $0) == 24 * 60 * 60 },
            "明确限流或拒绝访问未保留安全冷却"
        )
        passed.append("ordinary failures do not trigger global risk cooldown")

        let officialVerificationURL = URL(
            string: "https://www.zhipin.com/web/passport/zp/verify.html?callbackUrl=%2Fweb%2Fgeek%2Frecommend&code=36"
        )
        let officialSecurityCheckURL = URL(
            string: "https://www.zhipin.com/security-check?code=121"
        )
        let ordinaryBossURL = URL(
            string: "https://www.zhipin.com/web/geek/job?code=36"
        )
        let foreignVerificationURL = URL(
            string: "https://example.com/verify?code=36"
        )
        let unsupportedVerificationURL = URL(
            string: "https://www.zhipin.com/web/passport/zp/verify.html?code=37"
        )
        try verify(
            BossManualVerificationPagePolicy.evidence(from: officialVerificationURL)?.code == 36 &&
            BossManualVerificationPagePolicy.evidence(from: officialSecurityCheckURL)?.code == 121 &&
            BossManualVerificationPagePolicy.evidence(from: ordinaryBossURL) == nil &&
            BossManualVerificationPagePolicy.evidence(from: foreignVerificationURL) == nil &&
            BossManualVerificationPagePolicy.evidence(from: unsupportedVerificationURL) == nil,
            "BOSS 官方验证页识别范围过宽、遗漏已知验证码，或把普通/第三方页面误判为人工验证"
        )
        passed.append("boss official verification page policy")

        let riskStopURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-RiskStop-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: riskStopURL.deletingLastPathComponent()) }
        let riskStopPersistence = JSONStatePersistence(fileURL: riskStopURL)
        let riskStopStore = AppStore(persistence: riskStopPersistence)
        let riskStopAccountID = riskStopStore.addBossAccount()
        let riskStopAccount = try required(riskStopStore.snapshot.accounts.first, "缺少风险停机测试账号")
        riskStopStore.updateAutomation { $0.mode = .automatic; $0.workerEnabled = true }
        let riskStopController = BossAutomationController(api: BossAPIService(allowsWebFallback: false))
        riskStopController.registerManualVerificationPage(account: riskStopAccount, url: ordinaryBossURL, store: riskStopStore)
        try verify(riskStopStore.snapshot.automation.workerEnabled, "普通页面误触发风险停机")
        let riskDetectedAt = Date()
        riskStopController.registerManualVerificationPage(account: riskStopAccount, url: officialVerificationURL, store: riskStopStore)
        let riskStoppedSnapshot = try riskStopPersistence.load()
        let riskCooldownUntil = try required(riskStoppedSnapshot.automation.safetyCooldownUntil, "风险停机未持久化冷却")
        try verify(
            !riskStopController.isWorkerRunning && !riskStoppedSnapshot.automation.workerEnabled &&
            riskStoppedSnapshot.accounts.first?.id == riskStopAccountID &&
            riskCooldownUntil.timeIntervalSince(riskDetectedAt) >= 24 * 60 * 60 - 1,
            "安全验证后未停止后台并立即持久化 24 小时冷却"
        )
        let longerRiskCooldown = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            .addingTimeInterval(48 * 60 * 60)
        riskStopStore.updateAutomation { $0.safetyCooldownUntil = longerRiskCooldown }
        riskStopController.registerManualVerificationPage(account: riskStopAccount, url: officialVerificationURL, store: riskStopStore)
        try verify(riskStopStore.snapshot.automation.safetyCooldownUntil == longerRiskCooldown,
                   "重复安全验证缩短了已有冷却")
        let riskRestartStore = AppStore(persistence: riskStopPersistence)
        riskRestartStore.load()
        try verify(!riskRestartStore.snapshot.automation.workerEnabled &&
                   riskRestartStore.snapshot.automation.safetyCooldownUntil != nil,
                   "重新加载后风险停机状态丢失")
        let riskStopSessions = BossSessionCoordinator()
        let riskStopCodex = CodexController()
        try verify(
            !riskStopController.startWorker(using: riskRestartStore, sessions: riskStopSessions, codex: riskStopCodex) &&
            !riskRestartStore.snapshot.automation.workerEnabled &&
            riskStopController.statusByAccount[riskStopAccountID]?.contains("安全冷却中") == true,
            "冷却期间仍允许启动后台等待自动恢复"
        )
        passed.append("risk stop survives restart and preserves longer cooldown")

        try verify(
            BossProfileRequestPolicy.requests.map(\.path) == [
                "/wapi/zpuser/wap/getUserInfo.json",
                "/wapi/zpgeek/resume/baseinfo/query.json",
                "/wapi/zpgeek/resume/expect/query.json",
                "/wapi/zpgeek/resume/eduexp/query.json",
                "/wapi/zpgeek/resume/workexp/query.json",
                "/wapi/zpgeek/resume/userdesc/query.json"
            ] &&
            BossProfileRequestPolicy.requests.map(\.isRequired) == [true, false, false, false, false, false] &&
            !BossProfileRequestPolicy.requests.contains { $0.path.contains("resume/status") },
            "账号资料链路没有把身份读取与可降级的简历资料读取分开"
        )
        passed.append("boss profile request compatibility")

        let resumeProtocolInspections = try BossResumeExchangeProtocolSelfCheck.inspections()
        let expectedResumeProtocolPaths = [
            "/web/geek/chat",
            "/wapi/zpgeek/resume/attachment/checkbox.json",
            "/wapi/zpgeek/resume/attachment/checkbox.json",
            "/wapi/zpupload/resume/uploadFile.json",
            "/wapi/zpgeek/resume/attachment/save.json",
            "/wapi/zpchat/exchange/test",
            "/wapi/zpchat/exchange/request",
            "/wapi/zpchat/exchange/testAccept",
            "/wapi/zpchat/exchange/accept",
            "/wapi/zpchat/geek/historyMsg",
            "/wapi/zpchat/group/historyMsg",
            "/wapi/zprelation/friend/getGeekFriendList.json"
        ]
        try verify(
            resumeProtocolInspections.count == 12 &&
            resumeProtocolInspections.map(\.endpointPath) == expectedResumeProtocolPaths &&
            resumeProtocolInspections.allSatisfy {
                guard let url = URL(string: $0.absoluteURL) else { return false }
                return OfficialBossLinkService.isOfficialURL(url)
            },
            "BOSS 附件简历协议端点分类或官方域名白名单失效"
        )
        let requestPreflightInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpchat/exchange/test" },
            "缺少附件简历 request 预检协议"
        )
        let acceptPreflightInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpchat/exchange/testAccept" },
            "缺少附件简历 accept 预检协议"
        )
        let uploadWriteInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpupload/resume/uploadFile.json" },
            "缺少附件简历上传写协议"
        )
        let saveAttachmentWriteInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpgeek/resume/attachment/save.json" },
            "缺少附件简历保存写协议"
        )
        let requestWriteInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpchat/exchange/request" },
            "缺少附件简历 request 写协议"
        )
        let acceptWriteInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpchat/exchange/accept" },
            "缺少附件简历 accept 写协议"
        )
        let attachmentListInspections = resumeProtocolInspections.filter {
            $0.endpointPath == "/wapi/zpgeek/resume/attachment/checkbox.json"
        }
        let attachmentListFromValues = attachmentListInspections.compactMap { inspection in
            inspection.queryItems.first { $0.name == "from" }?.value
        }.sorted()
        let individualHistoryInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpchat/geek/historyMsg" },
            "缺少 BOSS 单聊完整历史协议"
        )
        let groupHistoryInspection = try required(
            resumeProtocolInspections.first { $0.endpointPath == "/wapi/zpchat/group/historyMsg" },
            "缺少 BOSS 群聊完整历史协议"
        )
        let friendListInspection = try required(
            resumeProtocolInspections.first {
                $0.endpointPath == "/wapi/zprelation/friend/getGeekFriendList.json"
            },
            "缺少 BOSS 已知会话资料补全协议"
        )
        let individualHistoryQuery = Dictionary(
            uniqueKeysWithValues: individualHistoryInspection.queryItems.map {
                ($0.name, $0.value ?? "")
            }
        )
        let groupHistoryQuery = Dictionary(
            uniqueKeysWithValues: groupHistoryInspection.queryItems.map {
                ($0.name, $0.value ?? "")
            }
        )
        try verify(
            !requestPreflightInspection.writeMayHaveCommitted &&
            !acceptPreflightInspection.writeMayHaveCommitted &&
            requestPreflightInspection.responseState == .statusPreflight &&
            acceptPreflightInspection.responseState == .statusPreflight &&
            uploadWriteInspection.writeMayHaveCommitted &&
            saveAttachmentWriteInspection.writeMayHaveCommitted &&
            requestWriteInspection.writeMayHaveCommitted &&
            acceptWriteInspection.writeMayHaveCommitted &&
            uploadWriteInspection.method == "POST" &&
            uploadWriteInspection.bodyKind == .PDFMultipart &&
            saveAttachmentWriteInspection.method == "POST" &&
            saveAttachmentWriteInspection.bodyKind == .none &&
            requestWriteInspection.responseState == .requestCreatedAwaitingRecruiter &&
            acceptWriteInspection.responseState == .serverAcceptedUnverified &&
            resumeProtocolInspections
                .filter {
                    ![
                        uploadWriteInspection.endpointPath,
                        saveAttachmentWriteInspection.endpointPath,
                        requestWriteInspection.endpointPath,
                        acceptWriteInspection.endpointPath
                    ].contains($0.endpointPath)
                }
                .allSatisfy { !$0.writeMayHaveCommitted },
            "BOSS 附件简历预检被误标为写入，或 upload/save/exchange 真实写入未要求提交前授权"
        )
        try verify(
            BossAutomationController.attachmentListFrom(
                for: .requestRecruiterConfirmation
            ) == 2 &&
            BossAutomationController.attachmentListFrom(
                for: .acceptNativeRequest
            ) == 3 &&
            attachmentListInspections.count == 2 &&
            attachmentListFromValues == ["2", "3"] &&
            attachmentListInspections.allSatisfy {
                $0.method == "GET" && $0.bodyKind == .none && !$0.writeMayHaveCommitted
            },
            "type-3/type-4 简历附件列表未使用官方 from=2/from=3 语义"
        )
        try verify(
            individualHistoryInspection.method == "GET" &&
            individualHistoryInspection.bodyKind == .none &&
            individualHistoryQuery == [
                "bossId": "selfcheck-boss-id",
                "groupId": "",
                "maxMsgId": "0",
                "c": "20",
                "page": "1",
                "src": "0",
                "securityId": "selfcheck-security-id"
            ] &&
            groupHistoryInspection.method == "GET" &&
            groupHistoryInspection.bodyKind == .none &&
            groupHistoryQuery == [
                "gid": "selfcheck-group-id",
                "maxMsgId": "0",
                "count": "20",
                "page": "1"
            ] &&
            friendListInspection.method == "POST" &&
            friendListInspection.bodyKind == .formURLEncoded &&
            friendListInspection.queryItems.isEmpty &&
            friendListInspection.bodyFields == [
                BossResumeExchangeProtocolField(
                    name: "friendIds",
                    value: "selfcheck-friend-id"
                )
            ],
            "BOSS 历史 query 或已知 friendIds 补全合约不准确"
        )
        try verify(
            saveAttachmentWriteInspection.bodyKind == .none &&
            saveAttachmentWriteInspection.bodyFields.isEmpty &&
            Dictionary(
                uniqueKeysWithValues: saveAttachmentWriteInspection.queryItems.map {
                    ($0.name, $0.value ?? "")
                }
            ) == [
                "previewUrl": "selfcheck-preview-token",
                "annexType": "0",
                "from": "8"
            ],
            "BOSS 附件保存协议未使用官方 query-only POST，或错误构造了 JSON 请求体"
        )
        passed.append("resume protocol endpoint and write classification")

        let resumePDFRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-ResumeProtocolPDF-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: resumePDFRoot) }
        try FileManager.default.createDirectory(at: resumePDFRoot, withIntermediateDirectories: true)
        let resumeTextURL = resumePDFRoot.appendingPathComponent("resume.txt")
        let resumeTextData = Data("Java 和 Python 研发经历\n附件简历结构校验。".utf8)
        try resumeTextData.write(to: resumeTextURL, options: .atomic)
        let preparedResumePDF = try ResumeDeliveryFileService.prepare(
            sourceURL: resumeTextURL,
            expectedSourceSize: resumeTextData.count,
            deliveryDirectory: resumePDFRoot.appendingPathComponent("delivery", isDirectory: true)
        )
        let preparedResumePDFData = try Data(contentsOf: URL(fileURLWithPath: preparedResumePDF.path))
        let forgedPDFHeader = Data("%PDF-1.7\nnot-a-structural-pdf\n%%EOF".utf8)
        try verify(
            BossResumeExchangeProtocolSelfCheck.isStructurallyValidPDF(preparedResumePDFData) &&
            !BossResumeExchangeProtocolSelfCheck.isStructurallyValidPDF(forgedPDFHeader) &&
            !BossResumeExchangeProtocolSelfCheck.isStructurallyValidPDF(Data("plain text".utf8)),
            "附件简历 PDF 校验仅检查文件头，未验证真实结构"
        )
        passed.append("structural resume PDF validation")

        let firstHistoryRouteBatch = BossAutomationController.rotatedHistoryRouteIndices(
            routeCount: 45,
            limit: 20,
            offset: 0
        )
        let secondHistoryRouteBatch = BossAutomationController.rotatedHistoryRouteIndices(
            routeCount: 45,
            limit: 20,
            offset: firstHistoryRouteBatch.nextOffset
        )
        let thirdHistoryRouteBatch = BossAutomationController.rotatedHistoryRouteIndices(
            routeCount: 45,
            limit: 20,
            offset: secondHistoryRouteBatch.nextOffset
        )
        let coveredHistoryRouteIndices = Set(
            firstHistoryRouteBatch.indices +
                secondHistoryRouteBatch.indices +
                thirdHistoryRouteBatch.indices
        )
        try verify(
            firstHistoryRouteBatch.indices == Array(0..<20) &&
            secondHistoryRouteBatch.indices == Array(20..<40) &&
            thirdHistoryRouteBatch.indices == Array(40..<45) + Array(0..<15) &&
            coveredHistoryRouteIndices == Set(0..<45) &&
            thirdHistoryRouteBatch.nextOffset == 15,
            "完整历史每轮 20 个会话的轮转游标跳过了 20 个之后的会话"
        )
        let splitHistoryBudgets = BossAutomationController.historySynchronizationBudgets(
            unresolvedCount: 25,
            regularCount: 95,
            limit: 20
        )
        var unresolvedHistoryOffset = 0
        var regularHistoryOffset = 0
        var coveredUnresolvedHistoryRoutes = Set<Int>()
        var coveredRegularHistoryRoutes = Set<Int>()
        for _ in 0..<10 {
            let unresolvedBatch = BossAutomationController.rotatedHistoryRouteIndices(
                routeCount: 25,
                limit: splitHistoryBudgets.unresolved,
                offset: unresolvedHistoryOffset
            )
            unresolvedHistoryOffset = unresolvedBatch.nextOffset
            coveredUnresolvedHistoryRoutes.formUnion(unresolvedBatch.indices)
            let regularBatch = BossAutomationController.rotatedHistoryRouteIndices(
                routeCount: 95,
                limit: splitHistoryBudgets.regular,
                offset: regularHistoryOffset
            )
            regularHistoryOffset = regularBatch.nextOffset
            coveredRegularHistoryRoutes.formUnion(regularBatch.indices)
        }
        try verify(
            splitHistoryBudgets.unresolved > 0 &&
            splitHistoryBudgets.regular > 0 &&
            splitHistoryBudgets.unresolved + splitHistoryBudgets.regular == 20 &&
            coveredUnresolvedHistoryRoutes == Set(0..<25) &&
            coveredRegularHistoryRoutes == Set(0..<95),
            "未解决投递会话占满完整历史预算，导致普通会话长期饿死"
        )
        try verify(
            BossAutomationController.historySyncCompletion(
                historyReadFailureCount: 0,
                deferredRouteCount: 0,
                hasDeferredBackfill: false
            ) == .complete &&
            BossAutomationController.historySyncCompletion(
                historyReadFailureCount: 1,
                deferredRouteCount: 0,
                hasDeferredBackfill: false
            ) == .partial(failedRouteCount: 1) &&
            BossAutomationController.historySyncCompletion(
                historyReadFailureCount: 0,
                deferredRouteCount: 100,
                hasDeferredBackfill: false
            ) == .partial(failedRouteCount: 100) &&
            BossAutomationController.historySyncCompletion(
                historyReadFailureCount: 0,
                deferredRouteCount: 0,
                hasDeferredBackfill: true
            ) == .partial(failedRouteCount: 1),
            "完整历史存在失败、轮转延后或待续页时仍被标记为完整成功"
        )
        passed.append("full-history route rotation fairness")
        passed.append("partial full-history sync classification")

        try verify(
            BossAutomationController.validatedHistorySource(" 12 ") == 12 &&
            BossAutomationController.validatedHistorySource("0") == 0 &&
            BossAutomationController.validatedHistorySource(nil) == nil &&
            BossAutomationController.validatedHistorySource("") == nil &&
            BossAutomationController.validatedHistorySource("job") == nil &&
            BossAutomationController.validatedHistorySource("12x") == nil &&
            BossAutomationController.validatedHistorySource("-1") == nil &&
            BossAutomationController.validatedHistorySource("1.0") == nil,
            "非数字 friendSource 被静默接受为完整历史路由"
        )
        passed.append("strict history friend source validation")

        try verify(
            BossAutomationController.validatedHistoryContinuationPage(2) == 2 &&
            BossAutomationController.validatedHistoryContinuationPage(9) == 9 &&
            BossAutomationController.validatedHistoryContinuationPage(1) == nil &&
            BossAutomationController.validatedHistoryContinuationPage(0) == nil &&
            BossAutomationController.validatedHistoryContinuationPage(-1) == nil &&
            BossAutomationController.nextHistoryPage(after: 1) == 2 &&
            BossAutomationController.nextHistoryPage(after: 9) == 10 &&
            BossAutomationController.nextHistoryPage(after: 0) == nil &&
            BossAutomationController.nextHistoryPage(after: -1) == nil &&
            BossAutomationController.nextHistoryPage(after: Int.max) == nil,
            "完整历史续页页码未严格加一，或非续页/溢出页码未失败关闭"
        )
        passed.append("strict history continuation page validation")

        try verify(
            BossAutomationController.automaticResumeCommitSettingsAllow(
                isAutomaticMode: true,
                allowsExternalActions: true,
                automaticallyMonitorsMessages: true,
                automaticallySendsResume: true
            ) &&
            !BossAutomationController.automaticResumeCommitSettingsAllow(
                isAutomaticMode: true,
                allowsExternalActions: true,
                automaticallyMonitorsMessages: true,
                automaticallySendsResume: false
            ) &&
            !BossAutomationController.automaticResumeCommitSettingsAllow(
                isAutomaticMode: false,
                allowsExternalActions: false,
                automaticallyMonitorsMessages: true,
                automaticallySendsResume: true
            ),
            "自动简历开关在提交前关闭后仍允许执行外部写请求"
        )
        passed.append("automatic resume commit setting gate")

        var preferences = JobPreferences()
        preferences.requirementText = """
        目标岗位：Java 开发工程师
        必须 Spring Boot
        不考虑外包
        期望月薪：20-30K
        """
        preferences.plannedSearchQueries = ["Java"]
        let resume = ResumeProfile(name: "Java 简历", text: "Java Spring Boot", skills: ["Java", "Spring Boot"], targetRoles: ["Java"], yearsOfExperience: 5)
        var accepted = JobListing(id: "job-1", accountID: UUID(), title: "Java 开发工程师", company: "示例公司", location: "上海", salary: "20-35K", description: String(repeating: "Spring Boot Java 微服务经验。", count: 10))
        accepted.detailFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let acceptedAssessment = JobMatchingPolicy.assess(job: accepted, resume: resume, preferences: preferences)
        try verify(acceptedAssessment.passesQualityGate(minimumScore: preferences.minimumMatchScore), "合格岗位未通过质量门")
        passed.append("job quality gate")

        var summaryOnlyJob = accepted
        summaryOnlyJob.id = "boss-job-summary-only"
        summaryOnlyJob.remoteJobID = "summary-only-remote-job"
        summaryOnlyJob.securityID = "summary-only-security"
        summaryOnlyJob.detailFetchedAt = nil
        let summaryOnlyAssessment = JobMatchingPolicy.assess(
            job: summaryOnlyJob,
            resume: resume,
            preferences: preferences
        )
        try verify(
            summaryOnlyAssessment.score == 0 &&
            !summaryOnlyAssessment.passesQualityGate(
                minimumScore: preferences.minimumMatchScore
            ) &&
            summaryOnlyAssessment.greeting.isEmpty,
            "未取得 BOSS 权威职位描述时仍被推荐或生成了招呼语"
        )
        passed.append("authoritative job description gate")

        let legacyRecommendationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BossPilot-LegacyRecommendation-\(UUID().uuidString)/state.json"
            )
        defer {
            try? FileManager.default.removeItem(
                at: legacyRecommendationURL.deletingLastPathComponent()
            )
        }
        var legacyRecommendationState = AppSnapshot()
        legacyRecommendationState.schemaVersion = 11
        var legacyRecommendationAccount = BossAccount(displayName: "旧版岗位账号")
        legacyRecommendationAccount.id = summaryOnlyJob.accountID
        legacyRecommendationAccount.webProfileID = summaryOnlyJob.accountID
        var legacyRecommendationProfile = BossAccountProfile()
        legacyRecommendationProfile.remoteID = "legacy-summary-identity"
        legacyRecommendationProfile.name = "旧版岗位账号"
        legacyRecommendationAccount.remoteProfile = legacyRecommendationProfile
        legacyRecommendationState.accounts = [legacyRecommendationAccount]
        summaryOnlyJob.stage = .recommended
        summaryOnlyJob.assessment = JobAssessment(
            score: 90,
            recommendation: "推荐",
            confidence: .high,
            reasons: ["旧版仅依据摘要评估"],
            risks: [],
            greeting: "旧招呼语",
            assessedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "legacy"
        )
        legacyRecommendationState.jobs = [summaryOnlyJob]
        legacyRecommendationState.pendingActions = [PendingAction(
            accountID: summaryOnlyJob.accountID,
            jobID: summaryOnlyJob.id,
            kind: .sendGreeting,
            content: "旧招呼语",
            reason: "旧版摘要评估"
        )]
        let legacyRecommendationPersistence = JSONStatePersistence(
            fileURL: legacyRecommendationURL
        )
        try legacyRecommendationPersistence.save(legacyRecommendationState)
        let legacyRecommendationStore = AppStore(
            persistence: legacyRecommendationPersistence
        )
        legacyRecommendationStore.load()
        try verify(
            legacyRecommendationStore.snapshot.schemaVersion == 25 &&
            legacyRecommendationStore.snapshot.jobs.first?.stage == .discovered &&
            legacyRecommendationStore.snapshot.jobs.first?.assessment == nil &&
            !legacyRecommendationStore.snapshot.pendingActions.contains {
                $0.jobID == summaryOnlyJob.id && $0.kind == .sendGreeting
            },
            "旧版未取得职位描述的推荐和招呼待办未在升级后撤回"
        )
        passed.append("legacy summary-only recommendation migration")

        var strictPreferences = preferences
        strictPreferences.plannedCities = ["上海"]
        let richResume = ResumeProfile(
            name: "高分简历",
            text: "Java MySQL Redis Kafka Docker",
            skills: ["Java", "MySQL", "Redis", "Kafka", "Docker"],
            targetRoles: ["Java"],
            yearsOfExperience: 5
        )
        var missingRequiredJob = JobListing(
            id: "job-missing-required",
            accountID: accepted.accountID,
            title: "Java 开发工程师",
            company: "示例公司",
            location: "上海",
            salary: "20-35K",
            description: String(repeating: "Java MySQL Redis Kafka Docker 微服务。", count: 8)
        )
        missingRequiredJob.detailFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let missingRequiredAssessment = JobMatchingPolicy.assess(job: missingRequiredJob, resume: richResume, preferences: strictPreferences)
        try verify(
            missingRequiredAssessment.score >= strictPreferences.minimumMatchScore &&
            !missingRequiredAssessment.passesQualityGate(minimumScore: strictPreferences.minimumMatchScore),
            "高分但缺少必需关键词的岗位未失败关闭"
        )
        passed.append("required keyword gate")

        let excluded = JobListing(id: "job-2", accountID: accepted.accountID, title: "Java 外包工程师", company: "示例公司", description: "Spring Boot")
        try verify(JobMatchingPolicy.assess(job: excluded, resume: resume, preferences: preferences).score == 0, "排除项未失败关闭")
        passed.append("hard exclusion")

        var strictRangePreferences = JobPreferences()
        strictRangePreferences.requirementText = """
        岗位：Java开发工程师 / AI应用研发工程师 / 平台研发工程师
        薪资：预期20-30K，最低薪资大于30K的不考虑，最高薪资低于20K的不考虑，这条是严格排除。
        地域：北京优先，其次上海、广州、深圳，其他城市的不考虑，这条是严格排除。
        公司：不考0-20人的公司。屏蔽示例甲科技、示例丁技术、外包、OD、内包、劳务派遣。
        """
        strictRangePreferences.plannedSearchQueries = ["AI应用研发工程师"]
        strictRangePreferences.plannedCities = ["北京", "上海", "广州", "深圳"]
        var equivalentRoleTitleJob = JobListing(
            id: "job-equivalent-role-title",
            accountID: accepted.accountID,
            title: "后端开发工程师（AI应用及工程架构）",
            company: "上海示例科技",
            location: "上海",
            salary: "20-40K",
            description: String(repeating: "Agent RAG Java Python AI 应用研发。", count: 10)
        )
        equivalentRoleTitleJob.detailFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let equivalentRoleTitleAssessment = JobMatchingPolicy.assess(
            job: equivalentRoleTitleJob,
            resume: richResume,
            preferences: strictRangePreferences
        )
        try verify(
            equivalentRoleTitleAssessment.passesQualityGate(
                minimumScore: strictRangePreferences.minimumMatchScore
            ) &&
                equivalentRoleTitleAssessment.reasons.contains(where: {
                    $0.contains("岗位名称匹配目标方向")
                }),
            "同一岗位方向仅因研发/开发措辞或标题修饰不同而被误拒"
        )
        passed.append("equivalent job role title matching")
        var dailyInternship = JobListing(
            id: "job-daily-internship",
            accountID: accepted.accountID,
            title: "AI应用研发工程师",
            company: "杭州示例科技",
            location: "北京",
            salary: "450-500元/天",
            experience: "5天/周 4个月",
            description: String(repeating: "Agent RAG Java Python 应用研发。", count: 10)
        )
        dailyInternship.detailFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let dailyFailures = JobMatchingPolicy.hardGateFailures(
            job: dailyInternship,
            preferences: strictRangePreferences
        )
        let dailyAssessment = JobMatchingPolicy.assess(
            job: dailyInternship,
            resume: richResume,
            preferences: strictRangePreferences
        )
        try verify(
            dailyFailures.contains(where: { $0.contains("不是可核验的月薪") }) &&
            dailyAssessment.recommendation == "不建议" &&
            dailyAssessment.greeting.isEmpty &&
            !dailyAssessment.passesQualityGate(minimumScore: strictRangePreferences.minimumMatchScore),
            "日薪或实习类岗位在严格月薪要求下仍可进入自动开聊"
        )
        var boundarySalaryJob = dailyInternship
        boundarySalaryJob.id = "job-boundary-salary"
        boundarySalaryJob.salary = "10-20K"
        boundarySalaryJob.experience = "5年"
        let boundarySalaryAssessment = JobMatchingPolicy.assess(
            job: boundarySalaryJob,
            resume: richResume,
            preferences: strictRangePreferences
        )
        try verify(
            JobMatchingPolicy.hardGateFailures(
                job: boundarySalaryJob,
                preferences: strictRangePreferences
            ).isEmpty &&
            boundarySalaryAssessment.passesQualityGate(
                minimumScore: strictRangePreferences.minimumMatchScore
            ) &&
            boundarySalaryAssessment.risks.contains(where: { $0.contains("边界") }),
            "薪资在 20K 边界相交的岗位被错误严格排除"
        )
        var disjointSalaryJob = boundarySalaryJob
        disjointSalaryJob.id = "job-disjoint-salary"
        disjointSalaryJob.salary = "31-45K"
        try verify(
            JobMatchingPolicy.hardGateFailures(
                job: disjointSalaryJob,
                preferences: strictRangePreferences
            ).contains("薪资区间与期望无重合"),
            "最低薪资高于期望上限的岗位未严格排除"
        )
        var disallowedCityJob = dailyInternship
        disallowedCityJob.id = "job-disallowed-city"
        disallowedCityJob.location = "成都"
        disallowedCityJob.salary = "20-30K"
        try verify(
            JobMatchingPolicy.hardGateFailures(
                job: disallowedCityJob,
                preferences: strictRangePreferences
            ).contains("工作地点不在严格限定的城市范围"),
            "严格地域要求未失败关闭"
        )
        var excludedCompanyJob = disallowedCityJob
        excludedCompanyJob.id = "job-excluded-company"
        excludedCompanyJob.company = "示例甲科技"
        excludedCompanyJob.location = "深圳"
        try verify(
            JobMatchingPolicy.hardGateFailures(
                job: excludedCompanyJob,
                preferences: strictRangePreferences
            ).contains(where: { $0.contains("示例甲科技") }),
            "屏蔽公司未失败关闭"
        )
        var exclusionPreferences = JobPreferences()
        exclusionPreferences.requirementText = "只考虑社招，不考虑校招、实习类岗位。不考0-20人的公司。屏蔽示例甲科技、示例乙科技、示例丙信息、示例丁技术、示例戊网络、EXAMPLECO、外包、OD、内包、劳务派遣。"
        let parsedExclusions = JobSearchPlanningPolicy.explicitExcludedTerms(in: exclusionPreferences.requirementText)
        for term in ["校招", "实习", "示例甲科技", "示例乙科技", "示例丙信息", "示例丁技术", "示例戊网络", "EXAMPLECO", "外包", "OD", "内包", "劳务派遣"] {
            try verify(parsedExclusions.contains(term), "排除条件解析遗漏：\(term)")
        }
        for title in ["Java校招工程师", "校园招聘研发工程师", "2027届应届毕业生", "AI实习生", "AI intern",
                      "应用开发工程师-27届可转正-提供餐补", "2027 届 AI工程师", "在校生研发岗", "AI internship"] {
            var job = equivalentRoleTitleJob
            job.title = title
            try verify(!JobMatchingPolicy.hardGateFailures(job: job, preferences: exclusionPreferences).isEmpty,
                       "校招或实习岗位漏过硬门禁：\(title)")
        }
        exclusionPreferences.requirementText = "不投校招，不投示例甲科技、示例戊网络，屏蔽EXAMPLECO、示例乙科技。"
        for company in ["示例甲科技技术有限公司", "示例戊网络", "EXAMPLECO", "示例乙科技科技"] {
            var job = equivalentRoleTitleJob
            job.company = company
            try verify(!JobMatchingPolicy.hardGateFailures(job: job, preferences: exclusionPreferences).isEmpty,
                       "重复排除条件漏过企业：\(company)")
        }
        try verify(JobMatchingPolicy.hardGateFailures(job: equivalentRoleTitleJob, preferences: exclusionPreferences).isEmpty,
                   "正常社招岗位被排除条件误拒")
        passed.append("repeated exclusions and campus internship gates")
        passed.append("strict job requirement gates")

        let rejected = ConversationPolicy.classify("目前不合适，不用发简历")
        try verify(rejected.intent == .rejected && !rejected.shouldCreateResumeTask, "拒绝消息被误判为投递")
        passed.append("rejection precedence")

        let unsafeAcceptanceContexts = [
            "不可以发简历",
            "请问可以发简历吗？",
            "招聘方没有说可以发简历",
            "不是说可以发简历",
            "我没同意你可以发简历",
            "你是不是想问可以发简历",
            "好麻烦发简历",
            "好方便发简历",
            "方便发简历",
            "不可以聊一聊",
            "请问可以聊一聊吗？",
            "对方没有说可以聊一聊",
            "不是说可以沟通",
            "如果可以进一步沟通"
        ]
        try verify(
            unsafeAcceptanceContexts.allSatisfy {
                let decision = ConversationPolicy.classify($0)
                return decision.intent != .resumeAccepted && !decision.shouldCreateResumeTask
            },
            "否定或疑问语境被误判为同意接收简历"
        )
        passed.append("negated resume acceptance")

        let explicitAcceptanceContexts = [
            "可以发简历给我",
            "请发简历",
            "方便发一下简历",
            "请把简历发给我。",
            "发份简历",
            "简历发来",
            "我这边接受您的简历",
            "您好，请发简历"
        ]
        try verify(
            explicitAcceptanceContexts.allSatisfy {
                let decision = ConversationPolicy.classify($0)
                return decision.intent == .resumeAccepted && decision.shouldCreateResumeTask
            },
            "严格白名单漏掉明确接收简历句式"
        )
        passed.append("explicit resume acceptance")

        let explicitConversationAcceptanceContexts = [
            "可以聊一聊",
            "好的，可以聊一下",
            "可以进一步沟通",
            "愿意跟你聊聊",
            "没问题，进一步沟通"
        ]
        try verify(
            explicitConversationAcceptanceContexts.allSatisfy {
                let decision = ConversationPolicy.classify($0)
                return decision.intent == .resumeAccepted &&
                    decision.shouldCreateResumeTask &&
                    decision.confidence >= 0.90
            },
            "严格白名单漏掉明确同意继续沟通的句式"
        )
        passed.append("explicit conversation acceptance")

        let acceptedMessage = ChatMessage(id: "m1", direction: .incoming, text: "可以发简历给我", sentAt: Date())
        let blankMessage = ChatMessage(id: "m0", direction: .system, text: " \n\t ", sentAt: Date())
        let conversation = Conversation(id: "c1", accountID: accepted.accountID, recruiterName: "招聘方", company: "示例公司", jobTitle: "Java", messages: [acceptedMessage], unreadCount: 1, lastSyncedAt: Date(), sourceURL: "")
        let conversationWithBlankHistory = Conversation(id: "c2", accountID: accepted.accountID, recruiterName: "招聘方", company: "示例公司", jobTitle: "Python", messages: [acceptedMessage, blankMessage], unreadCount: 1, lastSyncedAt: Date(), sourceURL: "")
        try verify(
            !blankMessage.hasDisplayableText &&
            conversationWithBlankHistory.displayableMessages == [acceptedMessage] &&
            conversationWithBlankHistory.latestMessage == acceptedMessage,
            "空白消息未被展示层过滤，或覆盖了最近有效消息"
        )
        passed.append("blank message presentation filtering")
        let firstAction = try required(
            ConversationPolicy.resumeTask(for: conversation, latestMessage: acceptedMessage, existingActions: []),
            "明确接收简历未生成待办"
        )
        let duplicateAction = ConversationPolicy.resumeTask(for: conversation, latestMessage: acceptedMessage, existingActions: [firstAction])
        try verify(duplicateAction == nil, "重复轮询生成了重复投递待办")
        passed.append("resume task idempotency")

        try verify(PendingActionStatus.pending.requiresAttention && PendingActionStatus.copied.requiresAttention, "复制后待办计数不一致")
        try verify(!PendingActionStatus.completed.requiresAttention && !PendingActionStatus.dismissed.requiresAttention, "已完成待办未正确关闭")
        passed.append("outstanding task status")

        let workStateAction = PendingAction(
            accountID: conversation.accountID,
            conversationID: conversation.id,
            kind: .sendMessage,
            content: "",
            reason: "需要处理",
            createdAt: acceptedMessage.sentAt
        )
        try verify(
            ConversationPolicy.workState(
                for: conversation,
                actions: [workStateAction],
                deliveryRecords: []
            ) == .pending,
            "待处理会话未进入待处理分类"
        )
        var handledConversation = conversation
        handledConversation.handledAt = acceptedMessage.sentAt.addingTimeInterval(1)
        handledConversation.unreadCount = 0
        try verify(
            ConversationPolicy.workState(
                for: handledConversation,
                actions: [],
                deliveryRecords: []
            ) == .processed,
            "已处理会话未进入已处理分类"
        )
        let newerIncoming = ChatMessage(
            id: "m2",
            direction: .incoming,
            text: "请问还在看机会吗？",
            sentAt: acceptedMessage.sentAt.addingTimeInterval(2)
        )
        handledConversation.messages.append(newerIncoming)
        handledConversation.unreadCount = 1
        try verify(
            ConversationPolicy.workState(
                for: handledConversation,
                actions: [],
                deliveryRecords: []
            ) == .pending,
            "已处理会话收到新消息后未重新打开"
        )
        passed.append("conversation processed classification")

        let automationDecoder = JSONDecoder()
        let retiredNotificationSettings = try automationDecoder.decode(
            AutomationSettings.self,
            from: Data(#"{"remindersEnabled":true,"reminderMinutes":-1,"notifyOnAttentionMessages":true,"dailyGreetingLimit":125,"allowRecruiterTextToCodex":false}"#.utf8)
        )
        let retiredNotificationJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(retiredNotificationSettings)
        ) as? [String: Any]
        try verify(
            retiredNotificationJSON?["remindersEnabled"] == nil &&
            retiredNotificationJSON?["reminderMinutes"] == nil &&
            retiredNotificationJSON?["notifyOnAttentionMessages"] == nil &&
            retiredNotificationSettings.dailyGreetingLimit == 125 &&
            !retiredNotificationSettings.allowRecruiterTextToCodex &&
            !retiredNotificationSettings.workerEnabled,
            "旧提醒字段未清理，或影响了额度、授权与运行状态"
        )
        passed.append("retired notification fields ignored without changing active settings")

        let oversizedWorker = try automationDecoder.decode(
            AutomationSettings.self,
            from: Data("{\"monitorIntervalMinutes\":999,\"searchIntervalMinutes\":999,\"dailyGreetingLimit\":999,\"greetingIntervalSeconds\":9999}".utf8)
        )
        let defaultWorker = try automationDecoder.decode(
            AutomationSettings.self,
            from: Data("{}".utf8)
        )
        let undersizedWorker = try automationDecoder.decode(
            AutomationSettings.self,
            from: Data("{\"searchIntervalMinutes\":0,\"dailyGreetingLimit\":0,\"greetingIntervalSeconds\":0}".utf8)
        )
        try verify(
            oversizedWorker.monitorIntervalMinutes == 180 &&
            oversizedWorker.searchIntervalMinutes == 360 &&
            oversizedWorker.dailyGreetingLimit == 150 &&
            oversizedWorker.greetingIntervalSeconds == 1_800 &&
            defaultWorker.dailyGreetingLimit == 150 &&
            defaultWorker.monitorIntervalMinutes == 60 &&
            defaultWorker.searchIntervalMinutes == 60 &&
            defaultWorker.greetingIntervalSeconds == 180 &&
            undersizedWorker.dailyGreetingLimit == 1 &&
            undersizedWorker.searchIntervalMinutes == 30 &&
            undersizedWorker.greetingIntervalSeconds == 180,
            "自动任务间隔或每日外发上限未限制"
        )
        passed.append("automation bounds")
        let requestNow = Date(timeIntervalSince1970: 1_700_000_000)
        try verify(
            BossRequestPacingPolicy.nextAllowedAt(
                lastDispatchedAt: requestNow, lastWriteAt: requestNow.addingTimeInterval(-80),
                isWrite: true, readJitter: 2, writeJitter: 4, now: requestNow
            ) == requestNow.addingTimeInterval(12) &&
            BossRequestPacingPolicy.nextAllowedAt(
                lastDispatchedAt: requestNow, lastWriteAt: requestNow,
                isWrite: true, readJitter: 0, writeJitter: 0, now: requestNow
            ) == requestNow.addingTimeInterval(60) &&
            BossRequestPacingPolicy.nextAllowedAt(
                lastDispatchedAt: requestNow, lastWriteAt: requestNow,
                isWrite: true, readJitter: 2, writeJitter: 4, now: requestNow
            ) == requestNow.addingTimeInterval(64) &&
            BossRequestPacingPolicy.nextAllowedAt(
                lastDispatchedAt: requestNow, lastWriteAt: requestNow,
                isWrite: false, readJitter: 2, writeJitter: 4, now: requestNow
            ) == requestNow.addingTimeInterval(12),
            "读请求重置完整写等待或写请求突破全局间隔"
        )
        try verify(
            BossAutomationController.shouldReadHistoryBackfill(
                latestHeadMID: "100", backfillCursorMID: "50", latestSummaryMID: "100"
            ) &&
            !BossAutomationController.shouldReadHistoryBackfill(
                latestHeadMID: "100", backfillCursorMID: "50", latestSummaryMID: "101"
            ) &&
            !BossAutomationController.shouldReadHistoryBackfill(
                latestHeadMID: nil, backfillCursorMID: "50", latestSummaryMID: "100"
            ),
            "历史小批次未推进旧游标或新消息被旧历史阻塞"
        )
        let deliveryScheduleStart = Date(timeIntervalSince1970: 1_700_000_000)
        try verify(
            !AutomationWorkerSchedulePolicy.messageSyncIsDue(
                lastCompletedAt: deliveryScheduleStart, hasUnresolvedResumeDelivery: true,
                intervalMinutes: 60, now: deliveryScheduleStart.addingTimeInterval(179), hasReadyResumeDelivery: true
            ) && AutomationWorkerSchedulePolicy.messageSyncIsDue(
                lastCompletedAt: deliveryScheduleStart, hasUnresolvedResumeDelivery: true,
                intervalMinutes: 60, now: deliveryScheduleStart.addingTimeInterval(180), hasReadyResumeDelivery: true
            ) && !AutomationWorkerSchedulePolicy.messageSyncIsDue(
                lastCompletedAt: deliveryScheduleStart, hasUnresolvedResumeDelivery: true,
                intervalMinutes: 60, now: deliveryScheduleStart.addingTimeInterval(180)
            ) && AutomationWorkerSchedulePolicy.messageSyncIntervalMinutes(
                hasUnresolvedResumeDelivery: false, hasReadyResumeDelivery: false, intervalMinutes: 60
            ) == 60 && AutomationWorkerSchedulePolicy.messageSyncIntervalMinutes(
                hasUnresolvedResumeDelivery: true, hasReadyResumeDelivery: false, intervalMinutes: 60
            ) == 5,
            "投递队列未按三分钟跟进，或普通轮询与回读被提频"
        )
        passed.append("bounded resume follow-up scheduling preserves normal polling")
        passed.append("read write pacing and incremental history scheduling")
        let pacingRecord = AutomaticGreetingSafetyRecord(
            remoteIdentityID: "pacing-identity",
            remoteJobID: "pacing-job",
            attemptedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let pacingAllowedAt = AutomaticGreetingPacingPolicy.nextAllowedAt(
            after: pacingRecord,
            intervalSeconds: 30
        )
        try verify(
            AutomaticGreetingPacingPolicy.nextAllowedAt(
                after: pacingRecord,
                intervalSeconds: 30
            ) == pacingAllowedAt &&
            pacingAllowedAt.timeIntervalSince(pacingRecord.attemptedAt) >= 180 &&
            pacingAllowedAt.timeIntervalSince(pacingRecord.attemptedAt) <= 195 &&
            AutomaticGreetingPacingPolicy.maximumJitterSeconds == 15 &&
            BossAutomationController.startupWriteDelaySeconds == 15 &&
            BossRequestPacingPolicy.minimumReadIntervalSeconds == 10 &&
            BossRequestPacingPolicy.maximumReadJitterSeconds == 2 &&
            BossRequestPacingPolicy.minimumWriteIntervalSeconds == 60 &&
            BossRequestPacingPolicy.maximumWriteJitterSeconds == 4 &&
            AutomationWorkerSchedulePolicy.secondsUntilDue(
                lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000),
                intervalMinutes: 10,
                now: Date(timeIntervalSince1970: 1_700_000_300)
            ) == 300 &&
            AutomationWorkerSchedulePolicy.secondsUntilDue(
                lastCompletedAt: nil,
                intervalMinutes: 10,
                now: Date(timeIntervalSince1970: 1_700_000_300)
            ) == 10 &&
            !AutomationWorkerSchedulePolicy.jobSearchIsDue(
                lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000),
                intervalMinutes: 15,
                forceInitialSearch: false,
                now: Date(timeIntervalSince1970: 1_700_000_300)
            ) &&
            AutomationWorkerSchedulePolicy.jobSearchIsDue(
                lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000),
                intervalMinutes: 15,
                forceInitialSearch: true,
                now: Date(timeIntervalSince1970: 1_700_000_300)
            ) &&
            AutomationWorkerSchedulePolicy.boundedSleepSeconds([300, 900]) == 60 &&
            AutomationWorkerSchedulePolicy.boundedSleepSeconds(
                [2],
                minimumSeconds: AutomationWorkerSchedulePolicy.responsiveWakeFloorSeconds
            ) == 2 &&
            AutomationWorkerSchedulePolicy.boundedSleepSeconds(
                [0],
                minimumSeconds: AutomationWorkerSchedulePolicy.responsiveWakeFloorSeconds
            ) == AutomationWorkerSchedulePolicy.responsiveWakeFloorSeconds &&
            AutomationWorkerSchedulePolicy.messageSyncIsDue(
                lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasUnresolvedResumeDelivery: true,
                intervalMinutes: 10,
                now: Date(timeIntervalSince1970: 1_700_000_299)
            ) == false &&
            AutomationWorkerSchedulePolicy.messageSyncIsDue(
                lastCompletedAt: Date(timeIntervalSince1970: 1_700_000_000),
                hasUnresolvedResumeDelivery: true,
                intervalMinutes: 10,
                now: Date(timeIntervalSince1970: 1_700_000_300)
            ) &&
            JobDetailBatchPolicy.selectedIndices(
                hasCachedDetail: Array(repeating: false, count: 15),
                hasSecurityID: Array(repeating: true, count: 15)
            ) == Array(0..<4) &&
            JobDetailBatchPolicy.selectedIndices(
                hasCachedDetail: [true, false, false],
                hasSecurityID: [true, false, true]
            ) == [2] &&
            JobDetailBatchPolicy.startupAllocation(currentCount: 0, persistedCount: 290) == [0, 2] &&
            JobDetailBatchPolicy.startupAllocation(currentCount: 20, persistedCount: 290) == [2, 0] &&
            JobDetailBatchPolicy.startupAllocation(currentCount: 0, persistedCount: 0) == [0, 0] &&
            JobDetailBatchPolicy.allocation(currentCount: 20, persistedCount: 20) == [3, 1] &&
            JobDetailBatchPolicy.allocation(currentCount: 2, persistedCount: 20) == [2, 2] &&
            JobDetailBatchPolicy.allocation(currentCount: 20, persistedCount: 0) == [4, 0] &&
            JobDetailBatchPolicy.allocation(currentCount: 0, persistedCount: 20) == [0, 4] &&
            AutomationWorkerSchedulePolicy.detailBacklogIsDue(
                lastAttemptAt: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            ) &&
            !AutomationWorkerSchedulePolicy.detailBacklogIsDue(
                lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
                now: Date(timeIntervalSince1970: 1_700_000_899)
            ) &&
            AutomationWorkerSchedulePolicy.detailBacklogIsDue(
                lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
                now: Date(timeIntervalSince1970: 1_700_000_900)
            ),
            "自动开聊间隔或 worker 绝对到期时间不稳定"
        )
        var priorityJob = JobListing(id: "detail-priority", accountID: UUID(), title: "Java", company: "Example")
        priorityJob.remoteJobID = "detail-priority-remote"
        let priorityPreferences = JobPreferences()
        let priorityScores = try JobDetailBatchPolicy.priorityScores(jobs: [priorityJob], preferences: priorityPreferences)
        try verify(priorityScores["detail-priority-remote"] == JobMatchingPolicy.hardGateFailures(job: priorityJob, preferences: priorityPreferences).count,
                   "后台详情排序改变了匹配规则")
        try verify(
            JobDetailBatchPolicy.canReadDetail(lastFailureAt: nil, now: requestNow) &&
            !JobDetailBatchPolicy.canReadDetail(lastFailureAt: requestNow, now: requestNow.addingTimeInterval(899)) &&
            JobDetailBatchPolicy.canReadDetail(lastFailureAt: requestNow, now: requestNow.addingTimeInterval(900)),
            "失败的详情读取未退避或永久阻塞候选补充"
        )
        passed.append("job detail failure retry backoff")
        passed.append("cached job detail ranking preserves hard gates")
        passed.append("automatic greeting pacing")
        let automationNormalizationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-AutomationNormalization-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: automationNormalizationURL.deletingLastPathComponent()) }
        let automationNormalizationStore = AppStore(
            persistence: JSONStatePersistence(fileURL: automationNormalizationURL)
        )
        automationNormalizationStore.updateAutomation {
            $0.dailyGreetingLimit = 999
            $0.greetingIntervalSeconds = 9_999
        }
        try verify(
            automationNormalizationStore.snapshot.automation.dailyGreetingLimit == 150 &&
            automationNormalizationStore.snapshot.automation.greetingIntervalSeconds == 1_800,
            "运行时自动开聊配置未归一化到安全范围"
        )
        passed.append("automation store normalization")
        let automaticMode = try automationDecoder.decode(
            AutomationSettings.self,
            from: Data("{\"mode\":\"automatic\",\"automaticallySearchJobs\":false,\"automaticallyAssessJobs\":false,\"automaticallySendGreetings\":false}".utf8)
        )
        try verify(
            automaticMode.automaticallySearchJobs &&
            automaticMode.automaticallyAssessJobs &&
            automaticMode.automaticallySendGreetings,
            "自动模式未强制启用检索、匹配与开聊"
        )
        passed.append("automatic mode capability contract")
        let decodedResumeAutomation = try automationDecoder.decode(
            AutomationSettings.self,
            from: Data("{\"automaticallySendResume\":true}".utf8)
        )
        try verify(
            decodedResumeAutomation.automaticallySendResume &&
            AutomationSettings().allowsConnectorReads &&
            retiredNotificationSettings.allowsExternalActions && !retiredNotificationSettings.workerEnabled,
            "当前 schema 未保留用户明确开启的简历自动发送配置"
        )
        passed.append("resume automation setting decoding")

        let legacyPausedAccountID = UUID()
        let legacyPausedAccountJSON = """
        {
          "id": "\(legacyPausedAccountID.uuidString)",
          "displayName": "旧版误暂停账号",
          "status": "paused"
        }
        """
        let decodedLegacyPausedAccount = try JSONDecoder().decode(
            BossAccount.self,
            from: Data(legacyPausedAccountJSON.utf8)
        )
        try verify(
            decodedLegacyPausedAccount.id == legacyPausedAccountID &&
            decodedLegacyPausedAccount.status == .active,
            "旧版本地 paused 账号解码后仍被误风控禁用"
        )
        passed.append("legacy paused account recovery")

        let legacyResumeAutomationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-LegacyResumeAutomation-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: legacyResumeAutomationURL.deletingLastPathComponent()) }
        var legacyResumeAutomationState = AppSnapshot()
        legacyResumeAutomationState.schemaVersion = 7
        legacyResumeAutomationState.automation.automaticallySendResume = true
        var legacyResumeAccount = BossAccount(displayName: "旧版简历投递账号")
        var legacyResumeProfile = BossAccountProfile()
        legacyResumeProfile.remoteID = "legacy-resume-identity"
        legacyResumeProfile.name = "旧版简历投递账号"
        legacyResumeAccount.remoteProfile = legacyResumeProfile
        legacyResumeAutomationState.accounts = [legacyResumeAccount]
        let legacyConsentEvidence = ResumeConsentEvidence(
            accountID: legacyResumeAccount.id,
            remoteIdentityID: legacyResumeProfile.remoteID,
            conversationID: "boss-legacy-resume-conversation",
            triggerRemoteMID: "legacy-resume-mid",
            triggerTextDigest: String(repeating: "1", count: 64),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            exchangeKind: .requestRecruiterConfirmation,
            nativeActionAID: nil,
            nativeScene: nil
        )
        var interruptedLegacyResumeDelivery = ResumeDeliveryRecord(
            evidence: legacyConsentEvidence,
            attachmentSHA256: String(repeating: "2", count: 64),
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )
        interruptedLegacyResumeDelivery.state = .preparingAttachment
        legacyResumeAutomationState.resumeDeliveryRecords = [interruptedLegacyResumeDelivery]
        let legacyResumeAutomationPersistence = JSONStatePersistence(fileURL: legacyResumeAutomationURL)
        try legacyResumeAutomationPersistence.save(legacyResumeAutomationState)
        let legacyResumeAutomationStore = AppStore(persistence: legacyResumeAutomationPersistence)
        legacyResumeAutomationStore.load()
        let recoveredLegacyResumeDelivery = try legacyResumeAutomationStore.transitionResumeDelivery(
            recordID: interruptedLegacyResumeDelivery.id,
            to: .queued,
            now: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let encodedLegacyConsentSafety = String(
            decoding: try JSONEncoder().encode(
                legacyResumeAutomationStore.snapshot.resumeConsentSafetyRecords
            ),
            as: UTF8.self
        )
        try verify(
            legacyResumeAutomationStore.snapshot.schemaVersion == 25 &&
            !legacyResumeAutomationStore.snapshot.automation.automaticallySendResume &&
            ResumeDeliveryState.preparingAttachment.canTransition(to: .queued) &&
            recoveredLegacyResumeDelivery.state == .queued &&
            legacyResumeAutomationStore.snapshot.resumeConsentSafetyRecords.count == 1 &&
            !encodedLegacyConsentSafety.contains(legacyResumeProfile.remoteID) &&
            !encodedLegacyConsentSafety.contains(legacyConsentEvidence.triggerRemoteMID),
            "schema 8 之前的自动简历 true 未迁移为 false，附件准备中断未恢复可重试，或防重记录未迁移到 schema 11"
        )
        passed.append("legacy resume automation and safety migration")

        try verify(OfficialBossLinkService.isOfficialURL(URL(string: "https://www.zhipin.com/web/geek/job")!), "BOSS 官方 URL 被误拒绝")
        try verify(!OfficialBossLinkService.isOfficialURL(URL(string: "https://zhipin.com.example.org/login")!), "仿冒 BOSS URL 未被拒绝")
        try verify(!OfficialBossLinkService.isOfficialURL(URL(string: "https://zhipin.com@evil.example/login")!), "带 user-info 的仿冒 URL 未被拒绝")
        passed.append("official URL allowlist")

        let profileFixture = BossPayloadParser.accountProfile(
            userInfo: ["userInfo": ["encryptUserId": "geek-1", "name": "BOSS 用户"]],
            baseInfo: ["baseInfo": ["positionName": "Java 工程师", "cityName": "上海", "workYearDesc": "5 年"]],
            expectations: ["expectList": [["positionName": "后端工程师", "cityName": "杭州", "salaryDesc": "25-35K"]]],
            status: ["statusDesc": "在职，看看机会"],
            education: ["eduExpList": [["schoolName": "示例大学", "majorName": "软件工程", "degreeName": "硕士"]]],
            workHistory: ["workExpList": [["companyName": "示例科技", "positionName": "研发工程师"]]],
            selfDescription: ["userDesc": "负责研发平台架构与交付"]
        )
        try verify(
            profileFixture?.remoteID == "geek-1" &&
            profileFixture?.name == "BOSS 用户" &&
            profileFixture?.expectations.first?.contains("后端工程师") == true &&
            profileFixture?.educationSummary == "示例大学 · 软件工程 · 硕士" &&
            profileFixture?.recentWorkSummary == "示例科技 · 研发工程师" &&
            profileFixture?.selfDescription == "负责研发平台架构与交付",
            "BOSS 账号资料夹具解析失败"
        )
        let profileFixtureRoundTrip = profileFixture.flatMap { fixture in
            try? JSONDecoder().decode(
                BossAccountProfile.self,
                from: JSONEncoder().encode(fixture)
            )
        }
        try verify(
            profileFixtureRoundTrip?.educationSummary == "示例大学 · 软件工程 · 硕士" &&
            profileFixtureRoundTrip?.recentWorkSummary == "示例科技 · 研发工程师" &&
            profileFixtureRoundTrip?.selfDescription == "负责研发平台架构与交付",
            "BOSS 扩展账号资料未通过持久化往返"
        )
        passed.append("boss profile fixture")

        let identityURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Identity-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: identityURL.deletingLastPathComponent()) }
        let identityStore = AppStore(persistence: JSONStatePersistence(fileURL: identityURL))
        let identityAccountA = identityStore.addBossAccount()
        let identityAccountB = identityStore.addBossAccount()
        var profileA = BossAccountProfile()
        profileA.remoteID = "remote-geek-a"
        profileA.name = "账号甲"
        _ = try identityStore.applyBossProfile(profileA, accountID: identityAccountA)
        var duplicateRejected = false
        do {
            _ = try identityStore.applyBossProfile(profileA, accountID: identityAccountB)
        } catch BossAccountBindingError.duplicateIdentity {
            duplicateRejected = true
        }
        try verify(duplicateRejected, "同一 BOSS 身份被绑定到两个本地账号")

        var identityJob = JobListing(
            id: "boss-identity-job",
            accountID: identityAccountA,
            title: "Java",
            company: "示例公司"
        )
        identityJob.remoteJobID = "remote-job-a"
        identityStore.upsertJobs([identityJob])
        let identitySummary = BossFriendSummary(
            conversationID: "identity-conversation",
            recruiterName: "招聘方",
            company: "示例公司",
            jobTitle: "Java",
            latestText: "您好",
            unreadCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            securityID: "security",
            listID: "list",
            latestIsIncoming: true
        )
        _ = identityStore.upsertBossFriendSummaries([identitySummary], accountID: identityAccountA)
        identityStore.createDraftAction(
            accountID: identityAccountA,
            conversationID: nil,
            jobID: identityJob.id,
            kind: .sendGreeting,
            content: "草稿",
            reason: "测试"
        )
        var changedProfile = profileA
        changedProfile.remoteID = "remote-geek-b"
        changedProfile.name = "账号乙"
        let didChangeIdentity = try identityStore.applyBossProfile(changedProfile, accountID: identityAccountA)
        try verify(
            didChangeIdentity &&
            !identityStore.snapshot.jobs.contains(where: { $0.accountID == identityAccountA }) &&
            !identityStore.snapshot.conversations.contains(where: { $0.accountID == identityAccountA }) &&
            !identityStore.snapshot.pendingActions.contains(where: { $0.accountID == identityAccountA }),
            "同一本地账号切换 BOSS 身份后未清理旧身份数据"
        )
        var missingIdentityRejected = false
        var missingIdentityProfile = changedProfile
        missingIdentityProfile.remoteID = ""
        do {
            _ = try identityStore.applyBossProfile(missingIdentityProfile, accountID: identityAccountA)
        } catch BossAccountBindingError.remoteIdentityMissing {
            missingIdentityRejected = true
        }
        try verify(missingIdentityRejected, "已绑定账号在远端身份缺失时未失败关闭")
        let unboundIdentityStore = AppStore(
            persistence: JSONStatePersistence(
                fileURL: identityURL.deletingLastPathComponent().appendingPathComponent("unbound-state.json")
            )
        )
        let unboundAccountID = unboundIdentityStore.addBossAccount()
        var firstBindingWithoutIdentityRejected = false
        do {
            _ = try unboundIdentityStore.applyBossProfile(BossAccountProfile(), accountID: unboundAccountID)
        } catch BossAccountBindingError.remoteIdentityMissing {
            firstBindingWithoutIdentityRejected = true
        }
        try verify(firstBindingWithoutIdentityRejected, "首次绑定缺少远端身份时未失败关闭")
        var unboundLegacyJob = JobListing(
            id: "boss-unbound-legacy-job",
            accountID: unboundAccountID,
            title: "旧身份岗位",
            company: "未知身份公司"
        )
        unboundLegacyJob.remoteJobID = "unbound-legacy-remote-job"
        unboundIdentityStore.upsertJobs([unboundLegacyJob])
        var reboundProfile = BossAccountProfile()
        reboundProfile.remoteID = "verified-rebound-geek"
        reboundProfile.name = "已验证身份"
        let didRebindUnknownIdentity = try unboundIdentityStore.applyBossProfile(
            reboundProfile,
            accountID: unboundAccountID
        )
        try verify(
            didRebindUnknownIdentity &&
            unboundIdentityStore.snapshot.jobs.allSatisfy { $0.accountID != unboundAccountID },
            "首次稳定身份绑定时保留了无法归属的旧 BOSS 数据"
        )
        passed.append("boss account identity binding")

        let duplicateMigrationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-DuplicateIdentityMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: duplicateMigrationURL.deletingLastPathComponent()) }
        var duplicateIdentityState = AppSnapshot()
        duplicateIdentityState.schemaVersion = 1
        var duplicateOwner = BossAccount(displayName: "旧版主账号")
        duplicateOwner.createdAt = Date(timeIntervalSince1970: 100)
        duplicateOwner.loginStatus = .loggedIn
        var duplicateOwnerProfile = BossAccountProfile()
        duplicateOwnerProfile.remoteID = "shared-remote-geek"
        duplicateOwnerProfile.name = "远端用户"
        duplicateOwner.remoteProfile = duplicateOwnerProfile
        var duplicateSlot = BossAccount(displayName: "旧版重复账号")
        duplicateSlot.createdAt = Date(timeIntervalSince1970: 200)
        duplicateSlot.loginStatus = .loggedIn
        duplicateSlot.remoteProfile = duplicateOwnerProfile
        var unverifiableSlot = BossAccount(displayName: "旧版无身份账号")
        unverifiableSlot.createdAt = Date(timeIntervalSince1970: 300)
        unverifiableSlot.loginStatus = .loggedIn
        var unverifiableProfile = BossAccountProfile()
        unverifiableProfile.name = "缺少远端标识"
        unverifiableSlot.remoteProfile = unverifiableProfile
        var duplicateOwnerJob = JobListing(
            id: "boss-duplicate-owner-job",
            accountID: duplicateOwner.id,
            title: "Java",
            company: "主账号公司"
        )
        duplicateOwnerJob.remoteJobID = "owner-remote-job"
        var duplicateSlotJob = JobListing(
            id: "boss-duplicate-slot-job",
            accountID: duplicateSlot.id,
            title: "Python",
            company: "重复账号公司"
        )
        duplicateSlotJob.remoteJobID = "duplicate-remote-job"
        var unverifiableJob = JobListing(
            id: "boss-unverifiable-job",
            accountID: unverifiableSlot.id,
            title: "Go",
            company: "未知身份公司"
        )
        unverifiableJob.remoteJobID = "unverifiable-remote-job"
        duplicateIdentityState.accounts = [duplicateOwner, duplicateSlot, unverifiableSlot]
        duplicateIdentityState.jobs = [duplicateOwnerJob, duplicateSlotJob, unverifiableJob]
        duplicateIdentityState.pendingActions = [
            PendingAction(
                accountID: duplicateSlot.id,
                jobID: duplicateSlotJob.id,
                kind: .sendGreeting,
                content: "旧版重复动作",
                reason: "迁移测试"
            )
        ]
        let duplicateMigrationPersistence = JSONStatePersistence(fileURL: duplicateMigrationURL)
        try duplicateMigrationPersistence.save(duplicateIdentityState)
        let duplicateMigrationStore = AppStore(persistence: duplicateMigrationPersistence)
        duplicateMigrationStore.load()
        let migratedOwner = try required(
            duplicateMigrationStore.snapshot.accounts.first(where: { $0.id == duplicateOwner.id }),
            "重复身份迁移丢失主账号"
        )
        let migratedDuplicate = try required(
            duplicateMigrationStore.snapshot.accounts.first(where: { $0.id == duplicateSlot.id }),
            "重复身份迁移丢失待重登槽位"
        )
        let migratedUnverifiable = try required(
            duplicateMigrationStore.snapshot.accounts.first(where: { $0.id == unverifiableSlot.id }),
            "无稳定身份迁移丢失待重登槽位"
        )
        try verify(
            migratedOwner.remoteProfile?.remoteID == "shared-remote-geek" &&
            migratedOwner.loginStatus == .loggedIn &&
            migratedDuplicate.remoteProfile == nil &&
            migratedDuplicate.loginStatus == .loggedOut &&
            migratedUnverifiable.remoteProfile == nil &&
            migratedUnverifiable.loginStatus == .loggedOut &&
            duplicateMigrationStore.snapshot.jobs.map(\.id) == [duplicateOwnerJob.id] &&
            duplicateMigrationStore.snapshot.pendingActions.isEmpty,
            "旧状态中的重复 BOSS 身份未收敛为唯一所有者"
        )
        passed.append("legacy duplicate identity migration")

        let resumeFixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Resume-\(UUID().uuidString)", isDirectory: true)
        let resumeFixtureSource = resumeFixtureDirectory.appendingPathComponent("fixture.txt")
        let resumeFixtureStorage = resumeFixtureDirectory.appendingPathComponent("attachments", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: resumeFixtureDirectory) }
        try FileManager.default.createDirectory(at: resumeFixtureDirectory, withIntermediateDirectories: true)
        try Data("5 年 Java 开发经验，熟悉 Spring Boot、MySQL、Docker 和 Kubernetes。".utf8).write(to: resumeFixtureSource)
        let importedResume = try ResumeImportService.importAttachment(
            from: resumeFixtureSource,
            storageDirectory: resumeFixtureStorage
        )
        let storedAttachmentPath = try required(importedResume.attachmentPath, "附件简历未返回本地路径")
        let attachmentPermissions = try FileManager.default.attributesOfItem(atPath: storedAttachmentPath)[.posixPermissions] as? NSNumber
        let attachmentDirectoryPermissions = try FileManager.default.attributesOfItem(atPath: resumeFixtureStorage.path)[.posixPermissions] as? NSNumber
        try verify(
            FileManager.default.fileExists(atPath: storedAttachmentPath) &&
            importedResume.inferredSkills.contains("Java") &&
            importedResume.inferredSkills.contains("Spring Boot") &&
            importedResume.inferredYearsOfExperience == 5 &&
            attachmentPermissions?.intValue == 0o600 &&
            attachmentDirectoryPermissions?.intValue == 0o700,
            "附件简历未持久化或自动画像提取失败"
        )
        let replacementSource = resumeFixtureDirectory.appendingPathComponent("replacement.md")
        try Data("6 年 Python 开发经验，熟悉 FastAPI 和 Docker。".utf8).write(to: replacementSource)
        let replacementResume = try ResumeImportService.importAttachment(
            from: replacementSource,
            storageDirectory: resumeFixtureStorage
        )
        try verify(
            replacementResume.attachmentPath?.hasSuffix("current-resume.md") == true &&
            !FileManager.default.fileExists(atPath: storedAttachmentPath),
            "替换附件后仍保留旧格式简历"
        )
        let resumeRoundTripURL = resumeFixtureDirectory.appendingPathComponent("state.json")
        let resumeRoundTripStore = AppStore(persistence: JSONStatePersistence(fileURL: resumeRoundTripURL))
        resumeRoundTripStore.importResume(replacementResume)
        let firstImportedResumeID = resumeRoundTripStore.snapshot.resume.id
        resumeRoundTripStore.importResume(replacementResume)
        let secondImportedResumeID = resumeRoundTripStore.snapshot.resume.id
        resumeRoundTripStore.flush()
        let restoredResume = try JSONStatePersistence(fileURL: resumeRoundTripURL).load().resume
        try verify(
            firstImportedResumeID != secondImportedResumeID &&
            restoredResume.id == secondImportedResumeID &&
            restoredResume.attachmentPath == replacementResume.attachmentPath &&
            restoredResume.hasStoredAttachment,
            "同路径同尺寸附件连续导入未轮换简历版本 ID，或未通过 JSON 重启往返"
        )
        passed.append("resume attachment persistence")

        let gateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Gate-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: gateURL.deletingLastPathComponent()) }
        let gateStore = AppStore(persistence: JSONStatePersistence(fileURL: gateURL))
        gateStore.updateResume { $0 = richResume }
        gateStore.updatePreferences { $0 = strictPreferences }
        gateStore.upsertJobs([missingRequiredJob])
        _ = gateStore.assessJobLocally(id: missingRequiredJob.id)
        try verify(gateStore.snapshot.jobs.first?.stage == .rejected, "Store 未按硬门槛拒绝岗位")
        gateStore.flush()
        passed.append("store quality gate")

        let backlogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-AssessmentBacklog-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: backlogURL.deletingLastPathComponent()) }
        let backlogStore = AppStore(persistence: JSONStatePersistence(fileURL: backlogURL))
        backlogStore.updateResume { $0 = resume }
        backlogStore.updatePreferences { $0 = preferences }
        backlogStore.updateAutomation {
            $0.mode = .automatic
            $0.automaticallyAssessJobs = true
        }
        var backlogAccepted = accepted
        backlogAccepted.id = "backlog-accepted"
        var backlogRejected = accepted
        backlogRejected.id = "backlog-rejected"
        backlogRejected.title = "Java 外包工程师"
        var backlogWithoutDetail = summaryOnlyJob
        backlogWithoutDetail.id = "backlog-without-detail"
        backlogWithoutDetail.stage = .discovered
        backlogWithoutDetail.assessment = nil
        backlogStore.upsertJobs([backlogAccepted, backlogRejected, backlogWithoutDetail])
        let assessedBacklogCount = try completePendingAssessments(backlogStore, accountID: accepted.accountID)
        let assessedBacklogJobs = Dictionary(
            uniqueKeysWithValues: backlogStore.snapshot.jobs.map { ($0.id, $0) }
        )
        try verify(
            assessedBacklogCount == 2 &&
            assessedBacklogJobs[backlogAccepted.id]?.stage == .recommended &&
            assessedBacklogJobs[backlogRejected.id]?.stage == .rejected &&
            assessedBacklogJobs[backlogWithoutDetail.id]?.stage == .discovered &&
            assessedBacklogJobs[backlogWithoutDetail.id]?.assessment == nil,
            "已有完整职位描述的未评估岗位未及时补评估，或摘要岗位绕过了职位描述门禁"
        )
        var staleRejection = backlogStore.snapshot.jobs.first { $0.id == backlogAccepted.id }!
        staleRejection.id = "stale-negated-requirement"
        staleRejection.stage = .rejected
        staleRejection.assessment?.recommendation = "不建议"
        staleRejection.assessment?.risks = ["缺少必需关键词：其他城市"]
        staleRejection.assessment?.provider = "本地规则"
        backlogStore.upsertJobs([staleRejection])
        let restoredRejectionCount = try completePendingAssessments(backlogStore, accountID: accepted.accountID)
        let repeatedAssessmentCount = try completePendingAssessments(backlogStore, accountID: accepted.accountID)
        try verify(restoredRejectionCount == 1 &&
            backlogStore.snapshot.jobs.first { $0.id == staleRejection.id }?.stage == .recommended &&
            backlogStore.snapshot.jobs.first { $0.id == backlogRejected.id }?.stage == .rejected &&
            repeatedAssessmentCount == 0,
            "错误必需词导致的历史拒绝未恢复，或重复评估/放开了真实排除项")
        passed.append("pending authoritative job assessment backlog")

        let invalidationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Invalidation-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: invalidationURL.deletingLastPathComponent()) }
        let invalidationStore = AppStore(persistence: JSONStatePersistence(fileURL: invalidationURL))
        var originalJob = JobListing(id: "same-job", accountID: accepted.accountID, title: "Java 开发", company: "示例公司", description: "旧 JD")
        originalJob.detailFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        invalidationStore.upsertJobs([originalJob])
        let priorAssessment = JobAssessment(score: 80, recommendation: "推荐", confidence: .high, reasons: [], risks: [], greeting: "草稿", assessedAt: Date(), provider: "测试")
        invalidationStore.applyCodexAssessment(priorAssessment, to: originalJob.id)
        originalJob.description = "已更新的 JD"
        invalidationStore.upsertJobs([originalJob])
        try verify(invalidationStore.snapshot.jobs.first?.assessment == nil && invalidationStore.snapshot.jobs.first?.stage == .discovered, "JD 变更后仍复用旧评估")
        passed.append("job assessment invalidation")

        invalidationStore.applyCodexAssessment(priorAssessment, to: originalJob.id)
        invalidationStore.createDraftAction(
            accountID: originalJob.accountID,
            conversationID: nil,
            jobID: originalJob.id,
            kind: .sendGreeting,
            content: "旧招呼草稿",
            reason: "测试"
        )
        invalidationStore.updatePreferences { $0.requirementText = "必须满足新硬门槛" }
        try verify(
            invalidationStore.snapshot.jobs.first?.assessment == nil &&
            invalidationStore.snapshot.jobs.first?.stage == .discovered &&
            !invalidationStore.snapshot.pendingActions.contains { $0.kind == .sendGreeting && $0.status.requiresAttention },
            "偏好变更后旧评估或招呼待办仍有效"
        )
        passed.append("preference invalidation")

        invalidationStore.updatePreferences { $0 = JobPreferences() }
        invalidationStore.applyCodexAssessment(priorAssessment, to: originalJob.id)
        invalidationStore.createDraftAction(
            accountID: originalJob.accountID,
            conversationID: nil,
            jobID: originalJob.id,
            kind: .sendGreeting,
            content: "旧简历招呼草稿",
            reason: "测试"
        )
        invalidationStore.updateResume { $0.text = "已更新的简历正文" }
        try verify(
            invalidationStore.snapshot.jobs.first?.assessment == nil &&
            invalidationStore.snapshot.jobs.first?.stage == .discovered &&
            !invalidationStore.snapshot.pendingActions.contains { $0.kind == .sendGreeting && $0.status.requiresAttention },
            "简历变更后旧评估或招呼待办仍有效"
        )
        invalidationStore.flush()
        passed.append("resume invalidation")

        for legacyMode in ["remindersOnly", "draftsAndReminders", "automatic"] {
            let payload = Data("{\"mode\":\"\(legacyMode)\",\"workerEnabled\":true,\"remindersEnabled\":true,\"notifyOnAttentionMessages\":true}".utf8)
            let migrated = try automationDecoder.decode(AutomationSettings.self, from: payload)
            try verify(
                migrated.mode == .automatic &&
                migrated.workerEnabled == (legacyMode == "automatic") &&
                migrated.automaticallySearchJobs && migrated.automaticallyAssessJobs &&
                migrated.automaticallySendGreetings,
                "旧模式迁移后自动启动任务或保留通知"
            )
            let restored = try automationDecoder.decode(
                AutomationSettings.self, from: JSONEncoder().encode(migrated)
            )
            try verify(restored == migrated, "自动运行配置未持久化")
        }
        let automaticOnlyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-AutomaticOnly-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: automaticOnlyURL.deletingLastPathComponent()) }
        let automaticOnlyStore = AppStore(persistence: JSONStatePersistence(fileURL: automaticOnlyURL))
        automaticOnlyStore.updateAutomation {
            $0.mode = .remindersOnly
        }
        try verify(
            automaticOnlyStore.snapshot.automation.mode == .automatic &&
            !automaticOnlyStore.snapshot.automation.workerEnabled,
            "更新配置恢复了旧模式或自动启动了任务"
        )
        automaticOnlyStore.flush()
        passed.append("automatic-only migration preserves stopped worker")

        let remoteSyncURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-RemoteSync-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: remoteSyncURL.deletingLastPathComponent()) }
        let remoteSyncStore = AppStore(persistence: JSONStatePersistence(fileURL: remoteSyncURL))
        let remoteSummary = BossFriendSummary(
            conversationID: "boss-friend-1",
            recruiterName: "招聘方",
            company: "示例公司",
            jobTitle: "Java",
            latestText: "可以发简历给我",
            unreadCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            securityID: "security-id",
            listID: "list-id",
            latestIsIncoming: true
        )
        _ = remoteSyncStore.upsertBossFriendSummaries([remoteSummary], accountID: accepted.accountID)
        _ = remoteSyncStore.upsertBossFriendSummaries([remoteSummary], accountID: accepted.accountID)
        try verify(
            remoteSyncStore.snapshot.conversations.first?.messages.count == 1 &&
            remoteSyncStore.snapshot.pendingActions.filter { $0.kind == .sendResume }.isEmpty &&
            remoteSyncStore.authoritativeResumeConsentCandidates(accountID: accepted.accountID).isEmpty,
            "远端摘要同步未去重，或摘要错误创建了简历待办"
        )
        var newerMetadataSummary = remoteSummary
        newerMetadataSummary.recruiterName = "新招聘方"
        newerMetadataSummary.company = "新公司"
        newerMetadataSummary.jobTitle = "新岗位"
        newerMetadataSummary.jobSalary = "35-45K"
        newerMetadataSummary.jobLocation = "上海 · 浦东新区"
        newerMetadataSummary.securityID = "new-security-id"
        newerMetadataSummary.listID = "new-list-id"
        newerMetadataSummary.latestText = "稍后再聊"
        newerMetadataSummary.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        _ = remoteSyncStore.upsertBossFriendSummaries([newerMetadataSummary], accountID: accepted.accountID)
        var staleMetadataSummary = remoteSummary
        staleMetadataSummary.recruiterName = "旧招聘方"
        staleMetadataSummary.company = "旧公司"
        staleMetadataSummary.jobTitle = "旧岗位"
        staleMetadataSummary.jobSalary = "10-20K"
        staleMetadataSummary.jobLocation = "北京 · 朝阳区"
        staleMetadataSummary.securityID = "old-security-id"
        staleMetadataSummary.listID = "old-list-id"
        staleMetadataSummary.updatedAt = Date(timeIntervalSince1970: 1_699_999_999)
        _ = remoteSyncStore.upsertBossFriendSummaries([staleMetadataSummary], accountID: accepted.accountID)
        let metadataConversation = remoteSyncStore.snapshot.conversations.first
        let metadataConversationRoundTrip = metadataConversation.flatMap { conversation in
            try? JSONDecoder().decode(
                Conversation.self,
                from: JSONEncoder().encode(conversation)
            )
        }
        try verify(
            metadataConversation?.recruiterName == "新招聘方" &&
            metadataConversation?.company == "新公司" &&
            metadataConversation?.jobTitle == "新岗位" &&
            metadataConversation?.jobSalary == "35-45K" &&
            metadataConversation?.jobLocation == "上海 · 浦东新区" &&
            metadataConversationRoundTrip?.jobSalary == "35-45K" &&
            metadataConversationRoundTrip?.jobLocation == "上海 · 浦东新区" &&
            metadataConversation?.securityID == "new-security-id" &&
            metadataConversation?.listID == "new-list-id",
            "过期远端摘要回滚了会话元数据"
        )
        let attentionActionCount = remoteSyncStore.snapshot.pendingActions.filter {
            $0.kind == .sendMessage && $0.status.requiresAttention
        }.count
        var rejectedSummary = newerMetadataSummary
        rejectedSummary.latestText = "目前不太合适，谢谢"
        rejectedSummary.updatedAt = Date(timeIntervalSince1970: 1_700_000_101)
        _ = remoteSyncStore.upsertBossFriendSummaries([rejectedSummary], accountID: accepted.accountID)
        try verify(
            attentionActionCount == 0 &&
            remoteSyncStore.snapshot.pendingActions.filter {
                $0.kind == .sendMessage && $0.status.requiresAttention
            }.count == attentionActionCount,
            "沟通摘要错误创建了回复待办，或明确拒绝消息未被过滤"
        )
        var readRemoteSummary = newerMetadataSummary
        readRemoteSummary.unreadCount = 0
        readRemoteSummary.updatedAt = Date(timeIntervalSince1970: 1_700_000_102)
        _ = remoteSyncStore.upsertBossFriendSummaries([readRemoteSummary], accountID: accepted.accountID)
        try verify(remoteSyncStore.snapshot.conversations.first?.unreadCount == 0, "远端已读快照未覆盖本地未读数")
        let expiredPagePlaceholder = BossFriendSummary(
            conversationID: "expired-page-placeholder",
            recruiterName: "过期占位",
            company: "",
            jobTitle: "",
            latestText: "",
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            securityID: "",
            listID: "",
            encryptedBossID: "expired-boss",
            friendSource: "0"
        )
        _ = remoteSyncStore.upsertBossFriendSummaries(
            [expiredPagePlaceholder],
            accountID: accepted.accountID
        )
        try verify(
            remoteSyncStore.pruneUnrouteableBossConversationPlaceholders(
                accountID: accepted.accountID
            ) == 1 &&
            remoteSyncStore.snapshot.conversations.count == 1 &&
            remoteSyncStore.snapshot.conversations.first?.securityID == "new-security-id",
            "未清理没有 securityId/历史的 BOSS 页面过期占位会话"
        )
        remoteSyncStore.flush()
        passed.append("remote message idempotency")
        passed.append("recruiter message attention filtering")
        passed.append("expired page conversation placeholder pruning")

        let historySyncURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-HistorySync-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: historySyncURL.deletingLastPathComponent()) }
        let historySyncPersistence = JSONStatePersistence(fileURL: historySyncURL)
        let historySyncStore = AppStore(persistence: historySyncPersistence)
        let historyAccountID = historySyncStore.addBossAccount()
        var historyProfileA = BossAccountProfile()
        historyProfileA.remoteID = "history-geek-a"
        historyProfileA.name = "历史消息账号 A"
        _ = try historySyncStore.applyBossProfile(historyProfileA, accountID: historyAccountID)
        historySyncStore.synchronizeBossLoginStatus(accountID: historyAccountID, loggedIn: true)
        let historySummary = BossFriendSummary(
            conversationID: "history-conversation",
            recruiterName: "历史招聘方",
            company: "历史公司",
            jobTitle: "历史岗位",
            latestText: "请发简历",
            unreadCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            securityID: "history-security",
            listID: "history-list",
            latestIsIncoming: true,
            encryptedBossID: "history-boss",
            friendSource: "0",
            groupID: "history-group",
            latestRemoteMID: "1001",
            latestSenderID: "history-boss",
            latestRecipientID: historyProfileA.remoteID,
            latestMessageType: 1,
            latestActionAID: nil,
            latestScene: nil,
            latestDirectionIsAuthoritative: true
        )
        _ = historySyncStore.upsertBossFriendSummaries([historySummary], accountID: historyAccountID)
        let historyConversation = try required(
            historySyncStore.snapshot.conversations.first,
            "沟通摘要未建立完整历史同步目标"
        )
        try verify(
            historyConversation.encryptedBossID == historySummary.encryptedBossID &&
            historyConversation.friendSource == historySummary.friendSource &&
            historyConversation.groupID == historySummary.groupID &&
            historyConversation.latestMessage?.remoteMID == historySummary.latestRemoteMID &&
            historyConversation.latestMessage?.isAuthoritativeHistoryRecord == false &&
            historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID).isEmpty &&
            historySyncStore.snapshot.pendingActions.isEmpty,
            "BOSS 沟通摘要元数据未落库，或摘要错误授权了外发待办"
        )

        let historySyncStateDate = Date(timeIntervalSince1970: 1_700_001_000)
        historySyncStore.saveHistoryRouteRotationState(
            accountID: historyAccountID,
            unresolvedOffset: 21,
            regularOffset: 37,
            now: historySyncStateDate
        )
        historySyncStore.saveHistoryConversationSyncState(
            BossHistoryConversationSyncState(
                accountID: historyAccountID,
                remoteIdentityID: historyProfileA.remoteID,
                conversationID: historyConversation.id,
                latestHeadMID: "000250",
                gapCursorMID: "000240",
                gapTargetMID: "000245",
                gapNewHeadMID: "000260",
                gapNextPage: 3,
                backfillCursorMID: "000200",
                backfillNextPage: 9,
                updatedAt: historySyncStateDate
            )
        )
        historySyncStore.flush()
        let historySyncStateRoundTripStore = AppStore(persistence: historySyncPersistence)
        historySyncStateRoundTripStore.load()
        let restoredHistoryRotation = try required(
            historySyncStateRoundTripStore.historyRouteRotationState(accountID: historyAccountID),
            "重启后丢失完整历史路由轮转状态"
        )
        let restoredHistoryCursor = try required(
            historySyncStateRoundTripStore.historyConversationSyncState(
                accountID: historyAccountID,
                conversationID: historyConversation.id
            ),
            "重启后丢失完整历史会话游标状态"
        )
        let differentLocalSlotID = UUID()
        let otherSlotRotationID = BossHistoryRouteRotationState(
            accountID: differentLocalSlotID,
            remoteIdentityID: historyProfileA.remoteID,
            unresolvedOffset: 21,
            regularOffset: 37,
            updatedAt: historySyncStateDate
        ).id
        let otherSlotCursorID = BossHistoryConversationSyncState(
            accountID: differentLocalSlotID,
            remoteIdentityID: historyProfileA.remoteID,
            conversationID: historyConversation.id,
            latestHeadMID: nil,
            gapCursorMID: nil,
            gapTargetMID: nil,
            gapNewHeadMID: nil,
            backfillCursorMID: nil,
            updatedAt: historySyncStateDate
        ).id
        try verify(
            historySyncStateRoundTripStore.snapshot.schemaVersion == 25 &&
            restoredHistoryRotation.unresolvedOffset == 21 &&
            restoredHistoryRotation.regularOffset == 37 &&
            restoredHistoryCursor.latestHeadMID == "250" &&
            restoredHistoryCursor.gapCursorMID == "240" &&
            restoredHistoryCursor.gapTargetMID == "245" &&
            restoredHistoryCursor.gapNewHeadMID == "260" &&
            restoredHistoryCursor.gapNextPage == 3 &&
            restoredHistoryCursor.backfillCursorMID == "200" &&
            restoredHistoryCursor.backfillNextPage == 9 &&
            restoredHistoryRotation.id != otherSlotRotationID &&
            restoredHistoryCursor.id != otherSlotCursorID,
            "完整历史轮转、游标或配套页码未按账号持久化"
        )
        passed.append("durable full-history rotation and cursor state")

        let legacyHistoryPagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-LegacyHistoryPaging-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: legacyHistoryPagingURL.deletingLastPathComponent()) }
        var legacyHistoryPagingSnapshot = historySyncStateRoundTripStore.snapshot
        legacyHistoryPagingSnapshot.schemaVersion = 10
        legacyHistoryPagingSnapshot.historyConversationSyncStates = [
            BossHistoryConversationSyncState(
                accountID: historyAccountID,
                remoteIdentityID: historyProfileA.remoteID,
                conversationID: historyConversation.id,
                latestHeadMID: "250",
                gapCursorMID: "240",
                gapTargetMID: "245",
                gapNewHeadMID: "260",
                gapNextPage: 3,
                backfillCursorMID: "200",
                backfillNextPage: 9,
                updatedAt: historySyncStateDate
            )
        ]
        let legacyHistoryPagingPersistence = JSONStatePersistence(fileURL: legacyHistoryPagingURL)
        try legacyHistoryPagingPersistence.save(legacyHistoryPagingSnapshot)
        let migratedHistoryPagingStore = AppStore(persistence: legacyHistoryPagingPersistence)
        migratedHistoryPagingStore.load()
        let migratedHistoryPagingState = try required(
            migratedHistoryPagingStore.historyConversationSyncState(
                accountID: historyAccountID,
                conversationID: historyConversation.id
            ),
            "schema 10 完整历史状态迁移后丢失安全的 head MID"
        )
        try verify(
            migratedHistoryPagingStore.snapshot.schemaVersion == 25 &&
            migratedHistoryPagingState.latestHeadMID == "250" &&
            migratedHistoryPagingState.gapCursorMID == nil &&
            migratedHistoryPagingState.gapTargetMID == nil &&
            migratedHistoryPagingState.gapNewHeadMID == nil &&
            migratedHistoryPagingState.gapNextPage == 1 &&
            migratedHistoryPagingState.backfillCursorMID == nil &&
            migratedHistoryPagingState.backfillNextPage == 1,
            "schema 10 缺少可信 page 的 gap/backfill lane 未安全清空重建"
        )
        passed.append("legacy history paging migration")

        let plainConsentHistory = BossResumeHistoryMessage(
            messageID: "1001",
            timestampMilliseconds: 1_700_001_000_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "可以聊一聊",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: nil,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        var nativeConsentHistory = BossResumeHistoryMessage(
            messageID: "1002",
            timestampMilliseconds: 1_700_001_001_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        nativeConsentHistory.dialogButtonActionAID = 38
        nativeConsentHistory.dialogButtonScene = 1
        let questionHistory = BossResumeHistoryMessage(
            messageID: "1003",
            timestampMilliseconds: 1_700_001_002_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "请问你最快什么时候可以入职？",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: nil,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let rejectedHistory = BossResumeHistoryMessage(
            messageID: "1004",
            timestampMilliseconds: 1_700_001_003_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "目前不合适，不用回复",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let greetingHistory = BossResumeHistoryMessage(
            messageID: "1005",
            timestampMilliseconds: 1_700_001_004_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "您好",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: nil,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let unknownHistory = BossResumeHistoryMessage(
            messageID: "1006",
            timestampMilliseconds: 1_700_001_005_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "稍后联系",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let outgoingConsentLikeHistory = BossResumeHistoryMessage(
            messageID: "1007",
            timestampMilliseconds: 1_700_001_006_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "请发简历",
            senderID: historyProfileA.remoteID,
            recipientID: "history-boss",
            isSelf: true,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let greetingDeliveryText = "这是一条仅用于离线验收的招呼语"
        let confirmedGreetingHistory = BossResumeHistoryMessage(
            messageID: "2001",
            timestampMilliseconds: 1_700_001_006_500,
            messageType: 1,
            bodyType: 1,
            sanitizedText: greetingDeliveryText,
            senderID: historyProfileA.remoteID,
            recipientID: "history-boss",
            isSelf: nil,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let oldGreetingHistory = BossResumeHistoryMessage(
            messageID: "1999",
            timestampMilliseconds: 1_700_001_006_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: greetingDeliveryText,
            senderID: historyProfileA.remoteID,
            recipientID: "history-boss",
            isSelf: true,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let incomingGreetingHistory = BossResumeHistoryMessage(
            messageID: "2002",
            timestampMilliseconds: 1_700_001_007_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: greetingDeliveryText,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        try verify(
            BossGreetingDeliveryPolicy.confirmedMessage(
                in: [],
                text: greetingDeliveryText,
                currentUserID: historyProfileA.remoteID,
                newerThanMessageID: nil
            ) == nil,
            "friend/add 建联结果被错误当成招呼语送达"
        )
        try verify(
            BossGreetingDeliveryPolicy.confirmedMessage(
                in: [oldGreetingHistory, incomingGreetingHistory, confirmedGreetingHistory],
                text: greetingDeliveryText,
                currentUserID: historyProfileA.remoteID,
                newerThanMessageID: 2_000
            )?.messageID == "2001",
            "未仅通过精确出站文本、方向和新服务端 MID 确认招呼语"
        )
        try verify(
            BossGreetingDeliveryPolicy.confirmedMessage(
                in: [oldGreetingHistory, incomingGreetingHistory],
                text: greetingDeliveryText,
                currentUserID: historyProfileA.remoteID,
                newerThanMessageID: 2_000
            ) == nil,
            "旧 MID 或入站文本被错误当成新招呼语送达"
        )
        passed.append("automatic greeting requires authoritative outgoing history")
        var alreadyOperatedNativeHistory = BossResumeHistoryMessage(
            messageID: "1008",
            timestampMilliseconds: 1_700_001_007_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: true
        )
        alreadyOperatedNativeHistory.dialogButtonActionAID = 38
        alreadyOperatedNativeHistory.dialogButtonScene = 1
        var unknownOperatedNativeHistory = BossResumeHistoryMessage(
            messageID: "1009",
            timestampMilliseconds: 1_700_001_008_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: nil
        )
        unknownOperatedNativeHistory.dialogButtonActionAID = 38
        unknownOperatedNativeHistory.dialogButtonScene = 1
        let completeHistoryMessages = [
            plainConsentHistory,
            nativeConsentHistory,
            questionHistory,
            rejectedHistory,
            greetingHistory,
            unknownHistory,
            outgoingConsentLikeHistory,
            alreadyOperatedNativeHistory,
            unknownOperatedNativeHistory
        ]
        let firstHistoryOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: completeHistoryMessages,
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        let repeatedHistoryOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: completeHistoryMessages,
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        let authoritativeCandidates = historySyncStore.authoritativeResumeConsentCandidates(
            accountID: historyAccountID
        )
        let plainCandidate = try required(
            authoritativeCandidates.first { $0.triggerRemoteMID == plainConsentHistory.messageID },
            "权威普通文本同意未生成简历投递候选"
        )
        let nativeCandidate = try required(
            authoritativeCandidates.first { $0.triggerRemoteMID == nativeConsentHistory.messageID },
            "权威 BOSS 原生简历请求未生成简历投递候选"
        )
        let historySendMessageActions = historySyncStore.snapshot.pendingActions.filter {
            $0.kind == .sendMessage && $0.status.requiresAttention
        }
        try verify(
            firstHistoryOutcome.insertedMessageCount == 8 &&
            firstHistoryOutcome.refreshedMessageCount == 1 &&
            firstHistoryOutcome.authoritativeConsentCount == 2 &&
            repeatedHistoryOutcome.insertedMessageCount == 0 &&
            repeatedHistoryOutcome.refreshedMessageCount == 0 &&
            authoritativeCandidates.count == 2 &&
            plainCandidate.exchangeKind == .requestRecruiterConfirmation &&
            plainCandidate.nativeActionAID == nil &&
            nativeCandidate.exchangeKind == .acceptNativeRequest &&
            nativeCandidate.nativeActionAID == 38 &&
            nativeCandidate.nativeScene == 1 &&
            nativeCandidate.nativeDialogType == 2 &&
            nativeCandidate.nativeDialogWasOperated == false &&
            !authoritativeCandidates.contains {
                $0.triggerRemoteMID == alreadyOperatedNativeHistory.messageID ||
                    $0.triggerRemoteMID == unknownOperatedNativeHistory.messageID
            } &&
            historySendMessageActions.count == 1 &&
            historySendMessageActions.first?.conversationID == historyConversation.id &&
            historySyncStore.snapshot.pendingActions.filter {
                $0.kind == .sendResume && $0.status.requiresAttention
            }.count == 1,
            "BOSS 完整历史消息未按真实 MID 幂等落库，或权威同意/问题待办筛选错误"
        )
        try verify(
            historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID, conversationID: historyConversation.id) == authoritativeCandidates &&
            historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID, conversationID: historyConversation.remoteConversationID) == authoritativeCandidates &&
            historySyncStore.authoritativeResumeConsentCandidates(accountID: UUID(), conversationID: historyConversation.id).isEmpty,
            "限定会话的证据检索丢失权威同意、远端别名或账号隔离")
        passed.append("authoritative full-history sync and filtering")
        try verifyHistoryBatch(snapshot: historySyncStore.snapshot, conversation: historyConversation)
        passed.append("history batch publication, scoped evidence and numeric ordering")

        let numericChatUserID = "800001"
        let numericRecruiterID = "900001"
        let numericInboundHistory = BossResumeHistoryMessage(
            messageID: "1012",
            timestampMilliseconds: 1_700_001_008_500,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "您好，岗位还在招聘",
            senderID: numericRecruiterID,
            recipientID: numericChatUserID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let numericOutgoingHistory = BossResumeHistoryMessage(
            messageID: "1013",
            timestampMilliseconds: 1_700_001_008_600,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "您好，我对岗位感兴趣",
            senderID: numericChatUserID,
            recipientID: numericRecruiterID,
            isSelf: true,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let numericDirectionOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: [numericInboundHistory, numericOutgoingHistory],
            accountID: historyAccountID,
            conversationID: historyConversation.id,
            authoritativeCurrentUserID: numericChatUserID
        )
        let numericDirectionMessages = historySyncStore.snapshot.conversations
            .first { $0.id == historyConversation.id }?.messages ?? []
        try verify(
            historyProfileA.remoteID != numericChatUserID &&
            numericDirectionOutcome.insertedIncomingCount == 1 &&
            numericDirectionMessages.first(where: {
                $0.remoteMID == numericInboundHistory.messageID
            })?.direction == .incoming &&
            numericDirectionMessages.first(where: {
                $0.remoteMID == numericOutgoingHistory.messageID
            })?.direction == .outgoing,
            "加密资料 ID 与聊天数值 UID 不同时，完整历史消息方向识别失败"
        )
        passed.append("chat numeric identity direction binding")

        let missingButtonNativeHistory = BossResumeHistoryMessage(
            messageID: "1014",
            timestampMilliseconds: 1_700_001_009_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        var ambiguousDirectionNativeHistory = BossResumeHistoryMessage(
            messageID: "1015",
            timestampMilliseconds: 1_700_001_010_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: historyProfileA.remoteID,
            recipientID: historyProfileA.remoteID,
            isSelf: nil,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        ambiguousDirectionNativeHistory.dialogButtonActionAID = 38
        ambiguousDirectionNativeHistory.dialogButtonScene = 1
        var missingMIDNativeHistory = BossResumeHistoryMessage(
            messageID: "",
            timestampMilliseconds: 1_700_001_011_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        missingMIDNativeHistory.dialogButtonActionAID = 38
        missingMIDNativeHistory.dialogButtonScene = 1
        let incompleteNativeOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: [
                missingButtonNativeHistory,
                ambiguousDirectionNativeHistory,
                missingMIDNativeHistory
            ],
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        let candidatesAfterIncompleteNativeHistory = historySyncStore
            .authoritativeResumeConsentCandidates(accountID: historyAccountID)
        try verify(
            incompleteNativeOutcome.insertedMessageCount == 2 &&
            incompleteNativeOutcome.ignoredMessageCount == 1 &&
            candidatesAfterIncompleteNativeHistory.count == 2 &&
            !candidatesAfterIncompleteNativeHistory.contains {
                $0.triggerRemoteMID == missingButtonNativeHistory.messageID ||
                    $0.triggerRemoteMID == ambiguousDirectionNativeHistory.messageID
            },
            "缺少原生按钮 MID 或权威方向的历史消息仍授权了简历发送"
        )
        passed.append("incomplete native consent fails closed")

        var revocableSameMIDHistory = BossResumeHistoryMessage(
            messageID: "1016",
            timestampMilliseconds: 1_700_001_012_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: 40,
            actionAnnexType: 0,
            actionScene: 7,
            actionWasOperated: false,
            dialogType: 2,
            dialogWasOperated: false
        )
        revocableSameMIDHistory.dialogButtonActionAID = 38
        revocableSameMIDHistory.dialogButtonScene = 1
        revocableSameMIDHistory.hyperLinkType = 1
        revocableSameMIDHistory.hyperLinkResumeToken = "stale-token-must-be-cleared"
        let initialRevocableOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: [revocableSameMIDHistory],
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        let initiallyRevocableCandidateExists = historySyncStore
            .authoritativeResumeConsentCandidates(accountID: historyAccountID)
            .contains { $0.triggerRemoteMID == revocableSameMIDHistory.messageID }
        let revokedSameMIDHistory = BossResumeHistoryMessage(
            messageID: revocableSameMIDHistory.messageID,
            timestampMilliseconds: 1_700_001_013_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: true
        )
        let revokedSameMIDOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: [revokedSameMIDHistory],
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        var missingSenderNativeHistory = BossResumeHistoryMessage(
            messageID: "1017",
            timestampMilliseconds: 1_700_001_014_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: nil,
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        missingSenderNativeHistory.dialogButtonActionAID = 38
        var missingRecipientNativeHistory = BossResumeHistoryMessage(
            messageID: "1018",
            timestampMilliseconds: 1_700_001_015_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: nil,
            isSelf: true,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        missingRecipientNativeHistory.dialogButtonActionAID = 38
        let contradictoryIsSelfQuestionHistory = BossResumeHistoryMessage(
            messageID: "1019",
            timestampMilliseconds: 1_700_001_016_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "请问你最快什么时候可以入职？",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: true,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        let strictDirectionOutcome = historySyncStore.upsertBossHistoryMessages(
            messages: [
                missingSenderNativeHistory,
                missingRecipientNativeHistory,
                contradictoryIsSelfQuestionHistory
            ],
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        let refreshedConversation = try required(
            historySyncStore.snapshot.conversations.first { $0.id == historyConversation.id },
            "同 MID 撤销证据后丢失历史会话"
        )
        let revokedStoredMessage = try required(
            refreshedConversation.messages.first {
                $0.remoteMID == revocableSameMIDHistory.messageID
            },
            "同 MID 权威刷新后丢失消息"
        )
        let missingSenderStoredMessage = try required(
            refreshedConversation.messages.first {
                $0.remoteMID == missingSenderNativeHistory.messageID
            },
            "缺失 sender 的历史消息未落库"
        )
        let missingRecipientStoredMessage = try required(
            refreshedConversation.messages.first {
                $0.remoteMID == missingRecipientNativeHistory.messageID
            },
            "缺失 recipient 的历史消息未落库"
        )
        let contradictoryIsSelfStoredMessage = try required(
            refreshedConversation.messages.first {
                $0.remoteMID == contradictoryIsSelfQuestionHistory.messageID
            },
            "isSelf 与身份链矛盾的历史消息未落库"
        )
        let candidatesAfterAuthoritativeReplacement = historySyncStore
            .authoritativeResumeConsentCandidates(accountID: historyAccountID)
        try verify(
            initialRevocableOutcome.insertedMessageCount == 1 &&
            initiallyRevocableCandidateExists &&
            revokedSameMIDOutcome.insertedMessageCount == 0 &&
            revokedSameMIDOutcome.refreshedMessageCount == 1 &&
            revokedStoredMessage.remoteActionAID == nil &&
            revokedStoredMessage.actionAnnexType == nil &&
            revokedStoredMessage.remoteScene == nil &&
            revokedStoredMessage.actionWasOperated == nil &&
            revokedStoredMessage.dialogWasOperated == true &&
            revokedStoredMessage.dialogButtonActionAID == nil &&
            revokedStoredMessage.dialogButtonScene == nil &&
            revokedStoredMessage.hyperLinkType == nil &&
            revokedStoredMessage.hyperLinkResumeToken == nil &&
            revokedStoredMessage.hasAuthoritativeConsentPayload == false &&
            !candidatesAfterAuthoritativeReplacement.contains {
                $0.triggerRemoteMID == revocableSameMIDHistory.messageID
            },
            "同 MID 后续权威历史未撤销旧按钮、action 或附件回读证据"
        )
        try verify(
            strictDirectionOutcome.insertedMessageCount == 3 &&
            strictDirectionOutcome.insertedIncomingCount == 1 &&
            missingSenderStoredMessage.direction == .system &&
            missingSenderStoredMessage.hasAuthoritativeDirection == false &&
            missingRecipientStoredMessage.direction == .system &&
            missingRecipientStoredMessage.hasAuthoritativeDirection == false &&
            contradictoryIsSelfStoredMessage.direction == .incoming &&
            contradictoryIsSelfStoredMessage.hasAuthoritativeDirection == true &&
            contradictoryIsSelfStoredMessage.intent == .question &&
            !candidatesAfterAuthoritativeReplacement.contains {
                $0.triggerRemoteMID == missingSenderNativeHistory.messageID ||
                    $0.triggerRemoteMID == missingRecipientNativeHistory.messageID
            },
            "历史方向仍使用 raw isSelf 授权，或缺失 sender/recipient 未失败关闭"
        )
        passed.append("same-MID authoritative proof replacement")
        passed.append("strict authoritative history direction")

        let resumeAttachmentDigest = String(repeating: "a", count: 64)
        let usableRemoteResumeAttachment = BossResumeAttachment(
            resumeToken: "history-resume-token",
            annexType: 0,
            displayName: "resume.pdf",
            suffixName: "pdf",
            isRestricted: false
        )
        let restrictedRemoteResumeAttachment = BossResumeAttachment(
            resumeToken: "history-resume-token",
            annexType: 0,
            displayName: "resume.pdf",
            suffixName: "pdf",
            isRestricted: true
        )
        let wrongAnnexRemoteResumeAttachment = BossResumeAttachment(
            resumeToken: "history-resume-token",
            annexType: 1,
            displayName: "resume.pdf",
            suffixName: "pdf",
            isRestricted: false
        )
        let secondUsableRemoteResumeAttachment = BossResumeAttachment(
            resumeToken: "history-second-resume-token",
            annexType: 0,
            displayName: "resume-2.pdf",
            suffixName: "pdf",
            isRestricted: false
        )
        let maintainedSelectorDigest = BossRemoteResumeBinding.selectorDigest(
            remoteIdentityID: historyProfileA.remoteID,
            remoteResumeToken: usableRemoteResumeAttachment.resumeToken
        )
        try verify(
            BossAutomationController.remoteResumeBindingIsUsable(
                remoteResumeToken: "history-resume-token",
                attachments: [usableRemoteResumeAttachment]
            ) &&
            !BossAutomationController.remoteResumeBindingIsUsable(
                remoteResumeToken: "wrong-token",
                attachments: [usableRemoteResumeAttachment]
            ) &&
            !BossAutomationController.remoteResumeBindingIsUsable(
                remoteResumeToken: "history-resume-token",
                attachments: [usableRemoteResumeAttachment, usableRemoteResumeAttachment]
            ) &&
            !BossAutomationController.remoteResumeBindingIsUsable(
                remoteResumeToken: "history-resume-token",
                attachments: [restrictedRemoteResumeAttachment]
            ) &&
            !BossAutomationController.remoteResumeBindingIsUsable(
                remoteResumeToken: "history-resume-token",
                attachments: [wrongAnnexRemoteResumeAttachment]
            ) &&
            BossAutomationController.uniqueBossMaintainedResumeAttachment(
                in: [usableRemoteResumeAttachment, restrictedRemoteResumeAttachment]
            ) == usableRemoteResumeAttachment &&
            BossAutomationController.uniqueBossMaintainedResumeAttachment(
                in: []
            ) == nil &&
            BossAutomationController.uniqueBossMaintainedResumeAttachment(
                in: [usableRemoteResumeAttachment, secondUsableRemoteResumeAttachment]
            ) == nil &&
            ResumeDeliveryDigestPolicy.normalizedAttachmentSHA256(maintainedSelectorDigest) != nil &&
            !maintainedSelectorDigest.contains(usableRemoteResumeAttachment.resumeToken),
            "BOSS 附件绑定或账号内唯一附件简历选择未按 token、annexType 0、非限制态与隐私摘要失败关闭"
        )
        passed.append("boss maintained resume selection and binding")
        try verify(
            !BossAutomationController.nativeEvidenceMayCreateSeparateDelivery(
                exchangeKind: .acceptNativeRequest,
                hasRelatedType3Delivery: true
            ) &&
            BossAutomationController.nativeEvidenceMayCreateSeparateDelivery(
                exchangeKind: .acceptNativeRequest,
                hasRelatedType3Delivery: false
            ) &&
            BossAutomationController.nativeEvidenceMayCreateSeparateDelivery(
                exchangeKind: .requestRecruiterConfirmation,
                hasRelatedType3Delivery: true
            ),
            "同一会话已有 type-3 简历请求后，新的原生 AID 38 仍生成了失联的第二条投递"
        )
        passed.append("type3 and native resume delivery correlation")

        let resumeReadbackAcceptedAt = Date(timeIntervalSince1970: 1_700_001_050)
        let resumeReadbackToken = "history-resume-token"
        var nativeReadbackRecord = ResumeDeliveryRecord(
            evidence: nativeCandidate,
            attachmentSHA256: resumeAttachmentDigest,
            now: resumeReadbackAcceptedAt
        )
        nativeReadbackRecord.state = .serverAcceptedUnverified
        nativeReadbackRecord.remoteResumeToken = resumeReadbackToken
        nativeReadbackRecord.writeStartedAt = resumeReadbackAcceptedAt
        nativeReadbackRecord.writeBaselineRemoteMID = "1009"
        nativeReadbackRecord.serverAcceptedAt = resumeReadbackAcceptedAt
        nativeReadbackRecord.updatedAt = resumeReadbackAcceptedAt
        var type3ReadbackRecord = ResumeDeliveryRecord(
            evidence: plainCandidate,
            attachmentSHA256: resumeAttachmentDigest,
            now: resumeReadbackAcceptedAt
        )
        type3ReadbackRecord.state = .requestCreatedAwaitingRecruiter
        type3ReadbackRecord.remoteResumeToken = resumeReadbackToken
        type3ReadbackRecord.writeStartedAt = resumeReadbackAcceptedAt
        type3ReadbackRecord.writeBaselineRemoteMID = "1009"
        type3ReadbackRecord.serverAcceptedAt = resumeReadbackAcceptedAt
        type3ReadbackRecord.updatedAt = resumeReadbackAcceptedAt
        var operatedNativeRequest = ChatMessage(
            id: "native-operated-readback",
            direction: .incoming,
            text: "",
            sentAt: resumeReadbackAcceptedAt.addingTimeInterval(1)
        )
        operatedNativeRequest.remoteMID = "1010"
        operatedNativeRequest.remoteSenderID = "history-boss"
        operatedNativeRequest.remoteRecipientID = historyProfileA.remoteID
        operatedNativeRequest.remoteBodyType = 7
        operatedNativeRequest.dialogType = 2
        operatedNativeRequest.dialogWasOperated = true
        operatedNativeRequest.dialogButtonActionAID = 38
        operatedNativeRequest.hasAuthoritativeDirection = true
        operatedNativeRequest.isAuthoritativeHistoryRecord = true
        operatedNativeRequest.hasAuthoritativeConsentPayload = true
        var genericOutgoingAction = ChatMessage(
            id: "generic-outgoing-action",
            direction: .outgoing,
            text: "",
            sentAt: resumeReadbackAcceptedAt.addingTimeInterval(2)
        )
        genericOutgoingAction.remoteMID = "1011"
        genericOutgoingAction.remoteSenderID = historyProfileA.remoteID
        genericOutgoingAction.remoteRecipientID = "history-boss"
        genericOutgoingAction.remoteActionAID = 40
        genericOutgoingAction.actionAnnexType = 0
        genericOutgoingAction.hasAuthoritativeDirection = true
        genericOutgoingAction.isAuthoritativeHistoryRecord = true
        var wrongTokenAttachmentReadback = ChatMessage(
            id: "wrong-token-attachment-readback",
            direction: .outgoing,
            text: "",
            sentAt: resumeReadbackAcceptedAt.addingTimeInterval(2)
        )
        wrongTokenAttachmentReadback.remoteMID = "1012"
        wrongTokenAttachmentReadback.remoteBodyType = 12
        wrongTokenAttachmentReadback.hyperLinkType = 1
        wrongTokenAttachmentReadback.hyperLinkResumeToken = "different-resume-token"
        wrongTokenAttachmentReadback.hasAuthoritativeDirection = true
        wrongTokenAttachmentReadback.isAuthoritativeHistoryRecord = true
        var staleAttachmentReadback = wrongTokenAttachmentReadback
        staleAttachmentReadback.id = "stale-attachment-readback"
        staleAttachmentReadback.remoteMID = "1009"
        staleAttachmentReadback.hyperLinkResumeToken = resumeReadbackToken
        var outgoingAttachmentReadback = wrongTokenAttachmentReadback
        outgoingAttachmentReadback.id = "outgoing-attachment-readback"
        outgoingAttachmentReadback.remoteMID = "1013"
        outgoingAttachmentReadback.hyperLinkResumeToken = resumeReadbackToken
        let insufficientResumeReadbackMessages = [
            operatedNativeRequest,
            genericOutgoingAction,
            wrongTokenAttachmentReadback,
            staleAttachmentReadback
        ]
        try verify(
            !BossAutomationController.nativeResumeDeliveryHasAuthoritativeReadback(
                record: nativeReadbackRecord,
                messages: insufficientResumeReadbackMessages
            ) &&
            !BossAutomationController.type3ResumeDeliveryHasAuthoritativeReadback(
                record: type3ReadbackRecord,
                messages: insufficientResumeReadbackMessages
            ) &&
            BossAutomationController.nativeResumeDeliveryHasAuthoritativeReadback(
                record: nativeReadbackRecord,
                messages: insufficientResumeReadbackMessages + [outgoingAttachmentReadback]
            ) &&
            BossAutomationController.type3ResumeDeliveryHasAuthoritativeReadback(
                record: type3ReadbackRecord,
                messages: insufficientResumeReadbackMessages + [outgoingAttachmentReadback]
            ),
            "入站 operated、通用 annex、错误 token 或旧 MID 被误判为已确认，或精确出站附件回读未确认"
        )
        passed.append("authoritative resume delivery readback")

        var forgedMIDConsent = plainCandidate
        forgedMIDConsent.triggerRemoteMID = "forged-1001"
        var rejectedForgedMID = false
        do {
            _ = try historySyncStore.prepareResumeDelivery(
                evidence: forgedMIDConsent,
                attachmentSHA256: resumeAttachmentDigest
            )
        } catch ResumeDeliveryStoreError.evidenceNotCurrentHistory {
            rejectedForgedMID = true
        }
        var forgedDigestConsent = plainCandidate
        let allZeroDigest = String(repeating: "0", count: 64)
        forgedDigestConsent.triggerTextDigest = plainCandidate.triggerTextDigest == allZeroDigest
            ? String(repeating: "1", count: 64)
            : allZeroDigest
        var rejectedForgedDigest = false
        do {
            _ = try historySyncStore.prepareResumeDelivery(
                evidence: forgedDigestConsent,
                attachmentSHA256: resumeAttachmentDigest
            )
        } catch ResumeDeliveryStoreError.evidenceNotCurrentHistory {
            rejectedForgedDigest = true
        }
        let preparedHistoryDelivery = try historySyncStore.prepareResumeDelivery(
            evidence: plainCandidate,
            attachmentSHA256: resumeAttachmentDigest,
            now: Date(timeIntervalSince1970: 1_700_001_100)
        )
        let encodedConsentSafety = String(
            decoding: try JSONEncoder().encode(historySyncStore.snapshot.resumeConsentSafetyRecords),
            as: UTF8.self
        )
        try verify(
            rejectedForgedMID &&
            rejectedForgedDigest &&
            preparedHistoryDelivery.triggerRemoteMID == plainCandidate.triggerRemoteMID &&
            historySyncStore.snapshot.resumeDeliveryRecords.count == 1 &&
            historySyncStore.snapshot.resumeConsentSafetyRecords.count == 1 &&
            historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID).isEmpty &&
            !encodedConsentSafety.contains(historyProfileA.remoteID) &&
            !encodedConsentSafety.contains(plainCandidate.conversationID) &&
            !encodedConsentSafety.contains(plainCandidate.triggerRemoteMID) &&
            !encodedConsentSafety.contains(plainCandidate.triggerTextDigest) &&
            !encodedConsentSafety.contains(resumeAttachmentDigest),
            "伪造 MID/摘要未失败关闭，已排队投递后仍保留第二候选，或防重台账泄露了原始标识"
        )
        passed.append("exact authoritative resume evidence gate")

        let promotionRemoteResumeToken = "history-promotion-resume-token"
        _ = try historySyncStore.saveRemoteResumeBinding(
            BossRemoteResumeBinding(
                accountID: historyAccountID,
                remoteIdentityID: historyProfileA.remoteID,
                attachmentSHA256: resumeAttachmentDigest,
                remoteResumeToken: promotionRemoteResumeToken,
                remoteDisplayName: "resume.pdf",
                uploadedAt: Date(timeIntervalSince1970: 1_700_001_101)
            )
        )
        let dispatchingType3Delivery = try historySyncStore.transitionResumeDelivery(
            recordID: preparedHistoryDelivery.id,
            to: .dispatching,
            remoteResumeToken: promotionRemoteResumeToken,
            writeBaselineRemoteMID: "1009",
            now: Date(timeIntervalSince1970: 1_700_001_101)
        )
        let awaitingType3Delivery = try historySyncStore.transitionResumeDelivery(
            recordID: dispatchingType3Delivery.id,
            to: .requestCreatedAwaitingRecruiter,
            remoteResumeToken: promotionRemoteResumeToken,
            now: Date(timeIntervalSince1970: 1_700_001_102)
        )
        var nativeFollowupHistory = BossResumeHistoryMessage(
            messageID: "2001",
            timestampMilliseconds: 1_700_001_103_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        nativeFollowupHistory.dialogButtonActionAID = 38
        nativeFollowupHistory.dialogButtonScene = 1
        _ = historySyncStore.upsertBossHistoryMessages(
            messages: [nativeFollowupHistory],
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        let nativeFollowupCandidate = try required(
            historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID)
                .first { $0.triggerRemoteMID == nativeFollowupHistory.messageID },
            "type-3 请求后的权威原生简历卡未生成提升证据"
        )
        var ambiguousAwaitingType3Delivery = awaitingType3Delivery
        ambiguousAwaitingType3Delivery.id += "-ambiguous"
        try verify(
            BossAutomationController.uniquelyPromotableType3RecordID(
                for: nativeFollowupCandidate,
                records: [awaitingType3Delivery]
            ) == awaitingType3Delivery.id &&
            BossAutomationController.uniquelyPromotableType3RecordID(
                for: nativeFollowupCandidate,
                records: [awaitingType3Delivery, ambiguousAwaitingType3Delivery]
            ) == nil,
            "type-3 请求未按同会话、时间与唯一性关联原生简历卡"
        )
        let promotedNativeDelivery = try historySyncStore.promoteResumeDeliveryToNativeDispatch(
            recordID: awaitingType3Delivery.id,
            evidence: nativeFollowupCandidate,
            remoteResumeToken: promotionRemoteResumeToken,
            writeBaselineRemoteMID: "1009",
            now: Date(timeIntervalSince1970: 1_700_001_104)
        )
        try verify(
            historySyncStore.snapshot.resumeDeliveryRecords.count == 1 &&
            historySyncStore.snapshot.resumeDeliveryRecords.first?.id == promotedNativeDelivery.id &&
            promotedNativeDelivery.id != awaitingType3Delivery.id &&
            promotedNativeDelivery.exchangeKind == .acceptNativeRequest &&
            promotedNativeDelivery.triggerRemoteMID == nativeFollowupHistory.messageID &&
            promotedNativeDelivery.nativeDialogType == 2 &&
            promotedNativeDelivery.nativeDialogWasOperated == false &&
            promotedNativeDelivery.state == .dispatching &&
            historySyncStore.snapshot.resumeConsentSafetyRecords.count == 2,
            "type-3 请求遇到后续权威原生简历卡时未原子提升同一投递记录"
        )
        passed.append("type3 to native resume delivery promotion")

        let acceptedPromotedDelivery = try historySyncStore.transitionResumeDelivery(
            recordID: promotedNativeDelivery.id,
            to: .serverAcceptedUnverified,
            remoteResumeToken: promotionRemoteResumeToken,
            now: Date(timeIntervalSince1970: 1_700_001_105)
        )
        let acceptedDeliveryDate = try required(
            acceptedPromotedDelivery.serverAcceptedAt,
            "BOSS 接受附件发送后缺少服务端接受时间"
        )
        try verify(
            ResumeDeliveryState.serverAcceptedUnverified.countsAsResumeExchange &&
            !ResumeDeliveryState.requestCreatedAwaitingRecruiter.countsAsResumeExchange &&
            historySyncStore.resumeExchangeCountToday(now: acceptedDeliveryDate) == 1,
            "BOSS 已接受附件发送操作但未计入已交换"
        )
        let confirmedPromotedDelivery = try historySyncStore.transitionResumeDelivery(
            recordID: acceptedPromotedDelivery.id,
            to: .confirmed,
            remoteResumeToken: promotionRemoteResumeToken,
            now: Date(timeIntervalSince1970: 1_700_001_106)
        )
        let confirmedDeliveryDate = try required(
            confirmedPromotedDelivery.verifiedAt,
            "已确认附件简历缺少回读确认时间"
        )
        let confirmedDeliveryNextDay = try required(
            Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: Calendar.current.startOfDay(for: confirmedDeliveryDate)
            ),
            "无法生成附件简历今日统计测试日期"
        )
        try verify(
            historySyncStore.resumeExchangeCountToday(now: confirmedDeliveryDate) == 1 &&
            historySyncStore.resumeExchangeCountToday(now: confirmedDeliveryNextDay) == 0,
            "附件简历今日已交换统计口径失效"
        )
        var exchangedJob = JobListing(
            id: "boss-confirmed-resume-job",
            accountID: historyAccountID,
            title: historySummary.jobTitle,
            company: historySummary.company
        )
        exchangedJob.securityID = historySummary.securityID
        exchangedJob.stage = .contacted
        var sameTextDifferentRouteJob = exchangedJob
        sameTextDifferentRouteJob.id = "boss-different-resume-route-job"
        sameTextDifferentRouteJob.securityID = "different-security-id"
        var legacyExchangedJob = sameTextDifferentRouteJob
        legacyExchangedJob.id = "boss-legacy-resume-sent-job"
        legacyExchangedJob.stage = .resumeSent
        historySyncStore.upsertJobs([exchangedJob, sameTextDifferentRouteJob, legacyExchangedJob])
        try verify(
            historySyncStore.hasResumeExchange(for: exchangedJob) &&
            historySyncStore.hasResumeExchange(for: sameTextDifferentRouteJob) &&
            historySyncStore.hasResumeExchange(for: legacyExchangedJob) &&
            JobStage.contacted.belongsToContactedCategory &&
            JobStage.resumeRequested.belongsToContactedCategory &&
            !JobStage.resumeSent.belongsToContactedCategory,
            "已确认简历未进入已交换分组，或错误匹配到其他岗位/仍留在已开聊分组"
        )
        passed.append("accepted resume exchange job category")
        try verify(historySyncStore.resumeExchangeDate(for: exchangedJob) == acceptedDeliveryDate &&
                   historySyncStore.resumeExchangeDate(for: sameTextDifferentRouteJob) == acceptedDeliveryDate,
                   "投递交换时间使用了回读确认时间，或路由刷新后丢失接受时间")
        try verifyListPerformance(snapshot: historySyncStore.snapshot, conversation: try required(
            historySyncStore.snapshot.conversations.first { $0.id == confirmedPromotedDelivery.conversationID },
            "缺少性能测试所需的会话"
        ),
                                  job: exchangedJob, record: confirmedPromotedDelivery)
        passed.append("large list performance and cache invalidation")
        let repeatedPlainConsentHistory = BossResumeHistoryMessage(
            messageID: "2002",
            timestampMilliseconds: 1_700_001_107_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "可以聊一聊",
            senderID: "history-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        _ = historySyncStore.upsertBossHistoryMessages(
            messages: [repeatedPlainConsentHistory],
            accountID: historyAccountID,
            conversationID: historyConversation.id
        )
        var repeatedPlainEvidence = plainCandidate
        repeatedPlainEvidence.triggerRemoteMID = repeatedPlainConsentHistory.messageID
        repeatedPlainEvidence.receivedAt = Date(timeIntervalSince1970: 1_700_001_107)
        var rejectedSecondConversationDelivery = false
        do {
            _ = try historySyncStore.prepareResumeDelivery(
                evidence: repeatedPlainEvidence,
                attachmentSHA256: resumeAttachmentDigest
            )
        } catch ResumeDeliveryStoreError.deliveryAlreadyExists {
            rejectedSecondConversationDelivery = true
        }
        try verify(
            rejectedSecondConversationDelivery &&
            !historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID)
                .contains { $0.triggerRemoteMID == repeatedPlainConsentHistory.messageID } &&
            historySyncStore.snapshot.resumeDeliveryRecords.count == 1,
            "同一招聘会话确认发送简历后，新的同意消息仍创建了第二次投递"
        )
        passed.append("confirmed resume blocks second delivery")

        var priorDeliverySummary = historySummary
        priorDeliverySummary.conversationID = "history-prior-delivery-conversation"
        priorDeliverySummary.securityID = "history-prior-delivery-security"
        priorDeliverySummary.listID = "history-prior-delivery-list"
        priorDeliverySummary.latestRemoteMID = "3002"
        _ = historySyncStore.upsertBossFriendSummaries(
            [priorDeliverySummary],
            accountID: historyAccountID
        )
        let priorDeliveryConversation = try required(
            historySyncStore.snapshot.conversations.first {
                $0.remoteConversationID == priorDeliverySummary.conversationID
            },
            "历史已投递防重测试未建立独立会话"
        )
        var priorOutgoingResumeHistory = BossResumeHistoryMessage(
            messageID: "3001",
            timestampMilliseconds: 1_700_001_108_000,
            messageType: 1,
            bodyType: 12,
            sanitizedText: nil,
            senderID: historyProfileA.remoteID,
            recipientID: "history-prior-delivery-boss",
            isSelf: true,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        priorOutgoingResumeHistory.hyperLinkType = 1
        priorOutgoingResumeHistory.hyperLinkResumeToken = "prior-delivery-resume-token"
        let consentAfterPriorDeliveryHistory = BossResumeHistoryMessage(
            messageID: "3002",
            timestampMilliseconds: 1_700_001_109_000,
            messageType: 1,
            bodyType: 1,
            sanitizedText: "可以聊一聊",
            senderID: "history-prior-delivery-boss",
            recipientID: historyProfileA.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: nil,
            dialogWasOperated: nil
        )
        _ = historySyncStore.upsertBossHistoryMessages(
            messages: [priorOutgoingResumeHistory, consentAfterPriorDeliveryHistory],
            accountID: historyAccountID,
            conversationID: priorDeliveryConversation.id
        )
        try verify(
            !historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID)
                .contains { $0.triggerRemoteMID == consentAfterPriorDeliveryHistory.messageID },
            "BOSS 权威历史已有出站附件简历时仍生成了二次投递候选"
        )
        passed.append("authoritative history blocks repeated resume delivery")

        var historyProfileB = BossAccountProfile()
        historyProfileB.remoteID = "history-geek-b"
        historyProfileB.name = "历史消息账号 B"
        _ = try historySyncStore.applyBossProfile(historyProfileB, accountID: historyAccountID)
        try verify(
            historySyncStore.snapshot.resumeDeliveryRecords.isEmpty &&
            historySyncStore.snapshot.conversations.isEmpty &&
            historySyncStore.snapshot.historyRouteRotationStates.isEmpty &&
            historySyncStore.snapshot.historyConversationSyncStates.isEmpty &&
            historySyncStore.snapshot.resumeConsentSafetyRecords.count == 2,
            "A 切换到 B 后未清理原始投递/历史游标，或意外删除了匿名防重台账"
        )
        _ = try historySyncStore.applyBossProfile(historyProfileA, accountID: historyAccountID)
        _ = historySyncStore.upsertBossFriendSummaries([historySummary], accountID: historyAccountID)
        let reboundConversation = try required(
            historySyncStore.snapshot.conversations.first,
            "A-B-A 切换后未重建 BOSS 会话"
        )
        _ = historySyncStore.upsertBossHistoryMessages(
            messages: [plainConsentHistory],
            accountID: historyAccountID,
            conversationID: reboundConversation.id
        )
        var rejectedReplayAfterRebind = false
        do {
            _ = try historySyncStore.prepareResumeDelivery(
                evidence: plainCandidate,
                attachmentSHA256: resumeAttachmentDigest
            )
        } catch ResumeDeliveryStoreError.duplicateConsent {
            rejectedReplayAfterRebind = true
        }
        historySyncStore.flush()
        let restoredHistorySyncStore = AppStore(persistence: historySyncPersistence)
        restoredHistorySyncStore.load()
        try verify(
            rejectedReplayAfterRebind &&
            historySyncStore.authoritativeResumeConsentCandidates(accountID: historyAccountID).isEmpty &&
            restoredHistorySyncStore.snapshot.schemaVersion == 25 &&
            restoredHistorySyncStore.snapshot.resumeDeliveryRecords.isEmpty &&
            restoredHistorySyncStore.snapshot.resumeConsentSafetyRecords.count == 2,
            "简历同意防重台账未跨 A-B-A 身份切换持久化，或同一同意被允许重发"
        )
        restoredHistorySyncStore.flush()
        passed.append("resume consent safety A-B-A replay protection")

        let automaticHistoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-AutomaticHistory-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: automaticHistoryURL.deletingLastPathComponent()) }
        let automaticHistoryStore = AppStore(
            persistence: JSONStatePersistence(fileURL: automaticHistoryURL)
        )
        let automaticHistoryAccountID = automaticHistoryStore.addBossAccount()
        var automaticHistoryProfile = BossAccountProfile()
        automaticHistoryProfile.remoteID = "automatic-history-geek"
        automaticHistoryProfile.name = "自动简历账号"
        _ = try automaticHistoryStore.applyBossProfile(
            automaticHistoryProfile,
            accountID: automaticHistoryAccountID
        )
        automaticHistoryStore.updateAutomation { $0.automaticallySendResume = true }
        var automaticHistorySummary = historySummary
        automaticHistorySummary.conversationID = "automatic-history-conversation"
        automaticHistorySummary.latestRemoteMID = "automatic-native-1"
        automaticHistorySummary.latestRecipientID = automaticHistoryProfile.remoteID
        _ = automaticHistoryStore.upsertBossFriendSummaries(
            [automaticHistorySummary],
            accountID: automaticHistoryAccountID
        )
        let automaticHistoryConversation = try required(
            automaticHistoryStore.snapshot.conversations.first,
            "自动简历测试未建立会话"
        )
        var automaticNativeHistory = BossResumeHistoryMessage(
            messageID: "automatic-native-1",
            timestampMilliseconds: 1_700_001_200_000,
            messageType: 2,
            bodyType: 7,
            sanitizedText: nil,
            senderID: "automatic-history-boss",
            recipientID: automaticHistoryProfile.remoteID,
            isSelf: false,
            actionID: nil,
            actionAnnexType: nil,
            actionScene: nil,
            actionWasOperated: nil,
            dialogType: 2,
            dialogWasOperated: false
        )
        automaticNativeHistory.dialogButtonActionAID = 38
        automaticNativeHistory.dialogButtonScene = 1
        _ = automaticHistoryStore.upsertBossHistoryMessages(
            messages: [automaticNativeHistory],
            accountID: automaticHistoryAccountID,
            conversationID: automaticHistoryConversation.id
        )
        try verify(
            automaticHistoryStore.authoritativeResumeConsentCandidates(
                accountID: automaticHistoryAccountID
            ).count == 1 &&
            automaticHistoryStore.snapshot.pendingActions.allSatisfy { $0.kind != .sendResume },
            "已开启自动简历发送时仍创建了手工 sendResume 待办"
        )
        let missingAutomaticAttachmentPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Missing-Automatic-Resume-不存在.pdf")
        var attachmentPreparationFailedBeforeLedger = false
        do {
            _ = try ResumeDeliveryFileService.prepareCurrentAttachment(
                path: missingAutomaticAttachmentPath.path,
                expectedSourceSize: 1
            )
        } catch ResumeDeliveryFileError.sourceDoesNotExist {
            attachmentPreparationFailedBeforeLedger = true
        }
        let candidateAfterAttachmentPreparationFailure = try required(
            automaticHistoryStore.authoritativeResumeConsentCandidates(
                accountID: automaticHistoryAccountID
            ).first,
            "附件准备失败后权威简历同意被永久耗尽"
        )
        try verify(
            attachmentPreparationFailedBeforeLedger &&
            automaticHistoryStore.snapshot.resumeDeliveryRecords.isEmpty &&
            automaticHistoryStore.snapshot.resumeConsentSafetyRecords.isEmpty &&
            candidateAfterAttachmentPreparationFailure.triggerRemoteMID == automaticNativeHistory.messageID,
            "附件准备失败前就创建了 delivery/consent 台账，导致后续无法重试"
        )
        let retryablePreflightFailure = BossResumeExchangeError.APIError(
            endpoint: "/wapi/zpchat/exchange/testAccept",
            code: 19,
            writeMayHaveCommitted: false
        )
        let isReadOnlyPreflightFailure: Bool
        if case .APIError(let endpoint, _, let writeMayHaveCommitted) = retryablePreflightFailure {
            isReadOnlyPreflightFailure = endpoint == "/wapi/zpchat/exchange/testAccept" &&
                !writeMayHaveCommitted
        } else {
            isReadOnlyPreflightFailure = false
        }
        let deliveryCountBeforePreflightFailure = automaticHistoryStore.snapshot
            .resumeDeliveryRecords.count
        let safetyCountBeforePreflightFailure = automaticHistoryStore.snapshot
            .resumeConsentSafetyRecords.count
        let candidateAfterPreflightFailure = try required(
            automaticHistoryStore.authoritativeResumeConsentCandidates(
                accountID: automaticHistoryAccountID
            ).first,
            "只读预检失败后权威简历同意被永久耗尽"
        )
        let preparedAfterPreflightRetry = try automaticHistoryStore.prepareResumeDelivery(
            evidence: candidateAfterPreflightFailure,
            attachmentSHA256: String(repeating: "b", count: 64),
            now: Date(timeIntervalSince1970: 1_700_001_201)
        )
        try verify(
            isReadOnlyPreflightFailure &&
            deliveryCountBeforePreflightFailure == 0 &&
            safetyCountBeforePreflightFailure == 0 &&
            preparedAfterPreflightRetry.triggerRemoteMID == automaticNativeHistory.messageID &&
            automaticHistoryStore.snapshot.resumeDeliveryRecords.count == 1 &&
            automaticHistoryStore.snapshot.resumeConsentSafetyRecords.count == 1,
            "只读预检失败提前写入了 consent 防重台账，导致后续安全重试无法准备投递"
        )
        automaticHistoryStore.flush()
        passed.append("automatic resume consent coordinator handoff")
        passed.append("attachment preparation preserves resume consent retry")
        passed.append("read-only preflight preserves resume consent retry")

        let friendFixture: [String: Any] = [
            "friendList": [[
                "friendId": "same-remote-id",
                "friendSource": "job",
                "lastMsg": "可以发简历给我",
                "num": 2,
                "updateTime": 1_700_000_000_000 as NSNumber
            ]]
        ]
        let parsedFriends = BossPayloadParser.friendSummaries(from: friendFixture)
        try verify(
            parsedFriends.first?.latestIsIncoming == true && parsedFriends.first?.unreadCount == 2,
            "字符串 lastMsg 未使用未读快照识别为招聘方来信"
        )
        let pageStoreFixture: [String: Any] = [
            "ready": true,
            "friendList": [[
                "friendId": "page-store-boss-id",
                "friendSource": "12",
                "name": "示例招聘方",
                "brandName": "示例科技",
                "jobName": "AI 应用研发工程师",
                "salaryDesc": "30-50K",
                "cityName": 101020100,
                "areaDistrict": "浦东新区",
                "lastText": "请问你最快什么时候可以入职？",
                "unreadCount": 1,
                "updateTime": 1_700_000_000_000 as NSNumber,
                "securityId": "page-security",
                "lid": "page-list",
                "encryptBossId": "page-store-boss-id",
                "lastMsg": [
                    "mid": "page-mid-1",
                    "fromId": "page-store-boss-id",
                    "toId": "page-geek-id",
                    "type": 1
                ]
            ]]
        ]
        let pageStoreSummaries = try BossPayloadParser.validatedFriendSummaries(
            from: pageStoreFixture
        )
        try verify(
            pageStoreSummaries.count == 1 &&
            pageStoreSummaries[0].recruiterName == "示例招聘方" &&
            pageStoreSummaries[0].company == "示例科技" &&
            pageStoreSummaries[0].jobTitle == "AI 应用研发工程师" &&
            pageStoreSummaries[0].jobSalary == "30-50K" &&
            pageStoreSummaries[0].jobLocation == "上海 · 浦东新区" &&
            pageStoreSummaries[0].friendSource == "12" &&
            pageStoreSummaries[0].latestRemoteMID == "page-mid-1" &&
            pageStoreSummaries[0].latestIsIncoming == true &&
            pageStoreSummaries[0].latestDirectionIsAuthoritative,
            "BOSS 消息页 store 会话未转换为可分页读取的权威摘要"
        )
        passed.append("boss page conversation store fixture")
        let missingTimestampFixture: [String: Any] = [
            "friendList": [[
                "friendId": "no-timestamp-id",
                "friendSource": "job",
                "lastMsg": "您好",
                "num": 1
            ]]
        ]
        let firstMissingTimestamp = BossPayloadParser.friendSummaries(from: missingTimestampFixture)
        let secondMissingTimestamp = BossPayloadParser.friendSummaries(from: missingTimestampFixture)
        try verify(
            firstMissingTimestamp.first?.updatedAt == Date(timeIntervalSince1970: 0) &&
            firstMissingTimestamp.first?.updatedAt == secondMissingTimestamp.first?.updatedAt,
            "缺少时间戳的远端摘要未生成稳定标识"
        )
        if let first = firstMissingTimestamp.first, let second = secondMissingTimestamp.first {
            _ = remoteSyncStore.upsertBossFriendSummaries([first], accountID: accepted.accountID)
            _ = remoteSyncStore.upsertBossFriendSummaries([second], accountID: accepted.accountID)
        }
        let missingTimestampConversationID = "boss-\(StableIdentifier.fnv1a64([accepted.accountID.uuidString, "boss-no-timestamp-id-job"].joined(separator: "|")))"
        try verify(
            remoteSyncStore.snapshot.conversations.first(where: { $0.id == missingTimestampConversationID })?.messages.count == 1,
            "重复同步无时间戳摘要时制造了重复消息"
        )
        var readIncomingSummary = remoteSummary
        readIncomingSummary.conversationID = "already-read-incoming"
        readIncomingSummary.unreadCount = 0
        readIncomingSummary.updatedAt = Date(timeIntervalSince1970: 1_700_000_030)
        _ = remoteSyncStore.upsertBossFriendSummaries([readIncomingSummary], accountID: accepted.accountID)
        let readIncomingConversationID = "boss-\(StableIdentifier.fnv1a64([accepted.accountID.uuidString, readIncomingSummary.conversationID].joined(separator: "|")))"
        try verify(
            remoteSyncStore.snapshot.conversations.first(where: { $0.id == readIncomingConversationID })?.unreadCount == 0,
            "首次同步已读来信时凭空增加未读数"
        )
        let jobFixture: [String: Any] = [
            "jobList": [[
                "encryptJobId": "stable-job-id",
                "securityId": "rotating-security-a",
                "jobName": "Java",
                "brandName": "示例公司",
                "salaryDesc": "20-30K",
                "postDescription": "负责 Java 微服务与 AI 应用平台的设计、开发和交付。",
                "brandIndustry": "企业服务",
                "brandScaleName": "100-499人",
                "bossName": "示例招聘方",
                "bossTitle": "技术经理",
                "skills": ["Spring Boot", "MySQL"],
                "welfareList": [["name": "五险一金"]]
            ]]
        ]
        let parsedJob = BossPayloadParser.jobs(from: jobFixture).first
        let pathIdentifiedJob = BossPayloadParser.jobs(from: [
            "jobList": [[
                "securityId": "path-security",
                "lid": "path-lid",
                "jobName": "Python",
                "brandName": "路径公司",
                "jobUrl": "/job_detail/path-stable-job.html"
            ]]
        ]).first
        try verify(
            parsedJob?.salary == "20-30K" &&
            parsedJob?.remoteJobID == "stable-job-id" &&
            parsedJob?.industry == "企业服务" &&
            parsedJob?.companySize == "100-499人" &&
            parsedJob?.recruiterName == "示例招聘方" &&
            parsedJob?.recruiterTitle == "技术经理" &&
            parsedJob?.tags == ["Spring Boot", "MySQL"] &&
            parsedJob?.benefits == ["五险一金"] &&
            parsedJob?.url.contains("/job_detail/stable-job-id.html") == true &&
            parsedJob?.url.contains("securityId=rotating-security-a") == true &&
            pathIdentifiedJob?.remoteJobID == "path-stable-job" &&
            pathIdentifiedJob?.listID == "path-lid",
            "BOSS 岗位证据字段解析失败"
        )
        if let parsedJob {
            let recruiterListing = parsedJob.listing(
                accountID: accepted.accountID,
                detailFetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try verify(
                recruiterListing.recruiterDisplayLabel == "示例招聘方 · 技术经理",
                "工作台岗位未优先显示 BOSS 招聘方而是本地账号名称"
            )
        }
        passed.append("boss payload fixtures")

        if let parsedJob {
            var rotatedJob = parsedJob
            rotatedJob.securityID = "rotating-security-b"
            let stableJobURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("BossPilot-StableJob-\(UUID().uuidString)/state.json")
            defer { try? FileManager.default.removeItem(at: stableJobURL.deletingLastPathComponent()) }
            let stableJobStore = AppStore(persistence: JSONStatePersistence(fileURL: stableJobURL))
            let stableAccountID = stableJobStore.addBossAccount()
            var stableProfile = BossAccountProfile()
            stableProfile.remoteID = "stable-job-test-identity"
            _ = try stableJobStore.applyBossProfile(stableProfile, accountID: stableAccountID)
            let detailFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let stableListingA = parsedJob.listing(
                accountID: stableAccountID,
                detailFetchedAt: detailFetchedAt
            )
            let stableListingB = rotatedJob.listing(
                accountID: stableAccountID,
                detailFetchedAt: detailFetchedAt
            )
            stableJobStore.upsertJobs([stableListingA])
            stableJobStore.setJobStage(id: stableListingA.id, stage: .recommended)
            try stableJobStore.prepareAutomaticGreeting(jobID: stableListingA.id)
            stableJobStore.upsertJobs([stableListingB])
            try verify(
                stableListingA.id == stableListingB.id &&
                stableJobStore.snapshot.jobs.count == 1 &&
                stableJobStore.snapshot.jobs.first?.securityID == "rotating-security-b" &&
                stableJobStore.snapshot.jobs.first?.stage == .greetingDrafted,
                "securityId 轮换时未使用稳定岗位 ID 保留外发账本"
            )
        }
        let securityOnlyJobs = BossPayloadParser.jobs(from: [
            "jobList": [
                ["securityId": "security-only-a", "jobName": "Java 开发", "brandName": "甲公司"],
                ["securityId": "security-only-b", "jobName": "Python 开发", "brandName": "乙公司"]
            ]
        ])
        try verify(
            securityOnlyJobs.count == 2 &&
            Set(securityOnlyJobs.map { $0.listing(accountID: accepted.accountID).id }).count == 2 &&
            securityOnlyJobs.allSatisfy { $0.stableRemoteKey != "path:/job_detail/" },
            "缺少稳定 ID 的岗位被通用 job_detail 路径错误折叠"
        )
        passed.append("stable remote job identity")

        let detailCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-DetailCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: detailCacheRoot) }
        let detailCachePersistence = JSONStatePersistence(fileURL: detailCacheRoot.appendingPathComponent("state.json"))
        let detailCacheStore = AppStore(persistence: detailCachePersistence)
        let cachedAccount = detailCacheStore.addBossAccount()
        let otherCachedAccount = detailCacheStore.addBossAccount()
        var cacheProfile = BossAccountProfile()
        cacheProfile.remoteID = "cache-account-identity"
        _ = try detailCacheStore.applyBossProfile(cacheProfile, accountID: cachedAccount)
        cacheProfile.remoteID = "other-cache-account-identity"
        _ = try detailCacheStore.applyBossProfile(cacheProfile, accountID: otherCachedAccount)
        var cachedDetail = accepted
        cachedDetail.id = "boss-cached-detail"
        cachedDetail.accountID = cachedAccount
        cachedDetail.remoteJobID = "cached-remote"
        cachedDetail.securityID = "old-security"
        cachedDetail.tags = ["Java"]
        detailCacheStore.upsertJobs([cachedDetail])
        detailCacheStore.flush()
        // 新建 store 模拟批次尚未完成时应用中断。
        let restoredDetails = AppStore(persistence: detailCachePersistence)
        restoredDetails.load()
        var summaryRefresh = cachedDetail
        summaryRefresh.description = ""
        summaryRefresh.detailFetchedAt = nil
        summaryRefresh.tags = nil
        summaryRefresh.securityID = "new-security"
        restoredDetails.upsertJobs([summaryRefresh])
        let retainedDetail = try required(restoredDetails.snapshot.jobs.first, "读取后未保存详情")
        try verify(retainedDetail.hasCachedDetail && retainedDetail.description == cachedDetail.description &&
                   retainedDetail.detailFetchedAt == cachedDetail.detailFetchedAt && retainedDetail.tags == ["Java"] &&
                   retainedDetail.securityID == "new-security", "列表刷新覆盖了已缓存详情或未更新路由")
        var otherSummary = summaryRefresh
        otherSummary.id = "boss-other-account-detail"
        otherSummary.accountID = otherCachedAccount
        restoredDetails.upsertJobs([otherSummary])
        try verify(restoredDetails.snapshot.jobs.first { $0.accountID == otherCachedAccount }?.hasCachedDetail == false,
                   "缓存跨账号复用")
        var emptyDetail = cachedDetail
        emptyDetail.id = "boss-empty-detail"
        emptyDetail.remoteJobID = "empty-remote"
        emptyDetail.description = ""
        restoredDetails.upsertJobs([emptyDetail])
        var emptySummaryRefresh = emptyDetail
        emptySummaryRefresh.detailFetchedAt = nil
        emptySummaryRefresh.description = "列表摘要不能代替完整职位描述"
        restoredDetails.upsertJobs([emptySummaryRefresh])
        restoredDetails.flush()
        let reloadedDetails = AppStore(persistence: detailCachePersistence)
        reloadedDetails.load()
        let reloadedEmpty = try required(reloadedDetails.snapshot.jobs.first { $0.id == emptyDetail.id }, "空详情读取记录未持久化")
        try verify(reloadedEmpty.hasCachedDetail && !reloadedEmpty.hasAuthoritativeDescription && reloadedEmpty.description.isEmpty,
                   "空详情重复入队或列表摘要被升级为权威描述")
        let cacheReadFlags = [retainedDetail.hasCachedDetail, reloadedEmpty.hasCachedDetail, otherSummary.hasCachedDetail]
        try verify(JobDetailBatchPolicy.selectedIndices(hasCachedDetail: cacheReadFlags, hasSecurityID: [true, true, true]) == [2],
                   "已保存详情重启后被重复请求，或漏读另一账号的详情")
        passed.append("durable job detail cache, empty responses and account isolation")


        try verify(
            BossCityResolver.code(for: "上海市") == "101020100" &&
            BossCityResolver.code(for: "阿克苏地区") == "101131000" &&
            BossCityResolver.code(for: "101280600") == "101280600" &&
            BossCityResolver.name(forCode: "101020100") == "上海" &&
            BossCityResolver.displayText(for: "101020100 · 浦东新区") == "上海 · 浦东新区" &&
            BossCityResolver.displayText(for: "999999999") == "地点未标注" &&
            BossCityResolver.code(for: "不存在的城市") == nil,
            "BOSS 城市编码与中文地点未正确双向转换"
        )
        passed.append("boss city localization and fail closed")

        let codedLocationJobs = BossPayloadParser.jobs(from: [
            "jobList": [[
                "jobName": "Agent 研发工程师",
                "brandName": "示例公司",
                "cityName": 101020100,
                "areaDistrict": "浦东新区"
            ]]
        ])
        try verify(
            codedLocationJobs.first?.location == "上海 · 浦东新区" &&
            codedLocationJobs.first?.listing(accountID: UUID()).displayLocation == "上海 · 浦东新区",
            "岗位解析或旧数据展示仍泄漏数字地点编码"
        )
        passed.append("boss job location localization")

        let emptyJobs = try BossPayloadParser.validatedJobs(from: ["jobList": []])
        let emptyFriends = try BossPayloadParser.validatedFriendSummaries(from: ["friendList": []])
        let emptyLiveFriends = try BossPayloadParser.validatedFriendSummaries(from: [String: Any]())
        try verify(emptyJobs.isEmpty, "合法空岗位列表未被接受")
        try verify(emptyFriends.isEmpty && emptyLiveFriends.isEmpty, "合法空沟通列表未被接受")
        var rejectedMalformedJobs = false
        do {
            _ = try BossPayloadParser.validatedJobs(from: ["unexpected": []])
        } catch BossAPIError.invalidPayload {
            rejectedMalformedJobs = true
        }
        var rejectedMalformedFriends = false
        do {
            _ = try BossPayloadParser.validatedFriendSummaries(from: ["unexpected": []])
        } catch BossAPIError.invalidPayload {
            rejectedMalformedFriends = true
        }
        try verify(rejectedMalformedJobs && rejectedMalformedFriends, "BOSS 协议结构变化被误判为合法空列表")
        passed.append("boss payload shape validation")

        let crossAccountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-CrossAccount-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: crossAccountURL.deletingLastPathComponent()) }
        let crossAccountStore = AppStore(persistence: JSONStatePersistence(fileURL: crossAccountURL))
        let secondAccountID = UUID()
        var harmlessSummary = remoteSummary
        harmlessSummary.conversationID = "shared-remote-id"
        harmlessSummary.latestText = "您好"
        harmlessSummary.updatedAt = Date(timeIntervalSince1970: 1_700_000_010)
        var acceptingSummary = harmlessSummary
        acceptingSummary.latestText = "请把简历发给我"
        acceptingSummary.updatedAt = Date(timeIntervalSince1970: 1_700_000_020)
        _ = crossAccountStore.upsertBossFriendSummaries([harmlessSummary], accountID: accepted.accountID)
        _ = crossAccountStore.upsertBossFriendSummaries([acceptingSummary], accountID: secondAccountID)
        try verify(
            Set(crossAccountStore.snapshot.conversations.map(\.id)).count == 2 &&
            crossAccountStore.snapshot.pendingActions.isEmpty &&
            crossAccountStore.authoritativeResumeConsentCandidates(accountID: accepted.accountID).isEmpty &&
            crossAccountStore.authoritativeResumeConsentCandidates(accountID: secondAccountID).isEmpty,
            "相同远端会话 ID 在多账号间串号"
        )
        crossAccountStore.flush()
        passed.append("remote conversation account isolation")

        let cascadeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Cascade-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: cascadeURL.deletingLastPathComponent()) }
        let cascadeStore = AppStore(persistence: JSONStatePersistence(fileURL: cascadeURL))
        cascadeStore.addAccount(named: "账号 A")
        let accountA = try required(cascadeStore.snapshot.accounts.first, "账号创建失败")
        var accountAProfile = BossAccountProfile()
        accountAProfile.remoteID = "greeting-identity-a"
        accountAProfile.name = "账号 A"
        _ = try cascadeStore.applyBossProfile(accountAProfile, accountID: accountA.id)

        let rejectedGreetingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-GreetingRejection-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: rejectedGreetingURL.deletingLastPathComponent()) }
        let rejectedGreetingNow = Date(timeIntervalSince1970: 1_700_000_000)
        var rejectedGreetingState = AppSnapshot()
        var rejectedGreetingAccount = BossAccount(displayName: "重试账号")
        var rejectedGreetingProfile = BossAccountProfile()
        rejectedGreetingProfile.remoteID = "retry-after-definitive-rejection"
        rejectedGreetingAccount.remoteProfile = rejectedGreetingProfile
        rejectedGreetingState.accounts = [rejectedGreetingAccount]
        var rejectedGreetingJob = JobListing(
            id: "definitive-rejection-job",
            accountID: rejectedGreetingAccount.id,
            title: "可重试岗位",
            company: "示例公司"
        )
        rejectedGreetingJob.description = "经 BOSS 详情接口返回的职位描述"
        rejectedGreetingJob.detailFetchedAt = rejectedGreetingNow
        rejectedGreetingJob.remoteJobID = "definitive-rejection-remote-job"
        rejectedGreetingJob.stage = .recommended
        rejectedGreetingState.jobs = [rejectedGreetingJob]
        rejectedGreetingState.conversations = [Conversation(
            id: "boss-excluded-resume-conversation", accountID: rejectedGreetingAccount.id,
            recruiterName: "招聘方", company: "示例甲科技技术有限公司", jobTitle: "Java研发工程师",
            messages: [], unreadCount: 0, lastSyncedAt: rejectedGreetingNow, sourceURL: ""
        )]
        let rejectedGreetingPersistence = JSONStatePersistence(fileURL: rejectedGreetingURL)
        try rejectedGreetingPersistence.save(rejectedGreetingState)
        let rejectedGreetingStore = AppStore(persistence: rejectedGreetingPersistence)
        rejectedGreetingStore.load()
        try rejectedGreetingStore.prepareAutomaticGreeting(
            jobID: rejectedGreetingJob.id,
            now: rejectedGreetingNow
        )
        try rejectedGreetingStore.releaseAutomaticGreetingReservationAfterDefinitiveRejection(
            jobID: rejectedGreetingJob.id
        )
        let rejectedGreetingReloadedStore = AppStore(persistence: rejectedGreetingPersistence)
        rejectedGreetingReloadedStore.load()
        try verify(
            rejectedGreetingReloadedStore.snapshot.jobs.first?.stage == .recommended &&
            rejectedGreetingReloadedStore.snapshot.automaticGreetingAttempts.isEmpty &&
            rejectedGreetingReloadedStore.snapshot.automaticGreetingSafetyRecords.isEmpty,
            "远端明确拒绝且未进入消息写入时，自动开聊预留未释放"
        )
        try rejectedGreetingReloadedStore.prepareAutomaticGreeting(
            jobID: rejectedGreetingJob.id,
            now: rejectedGreetingNow.addingTimeInterval(10)
        )
        rejectedGreetingReloadedStore.isEditingRequirements = true
        var editingBlockedWrite = false
        do {
            try rejectedGreetingReloadedStore.markAutomaticGreetingWriteStarted(jobID: rejectedGreetingJob.id)
        } catch BossAutomationError.operationNotReady { editingBlockedWrite = true }
        rejectedGreetingReloadedStore.isEditingRequirements = false
        let previousRequirements = rejectedGreetingReloadedStore.snapshot.preferences.requirementText
        rejectedGreetingReloadedStore.updatePreferences { $0.requirementText = "不投示例公司" }
        var changedRequirementsBlockedWrite = false
        do {
            try rejectedGreetingReloadedStore.markAutomaticGreetingWriteStarted(jobID: rejectedGreetingJob.id)
        } catch BossAutomationError.operationNotReady { changedRequirementsBlockedWrite = true }
        try verify(editingBlockedWrite && changedRequirementsBlockedWrite &&
                   rejectedGreetingReloadedStore.snapshot.automaticGreetingAttempts.first?.deliveryWriteStartedAt == nil,
                   "编辑中或新增排除条件后仍允许跨过消息发送边界")
        rejectedGreetingReloadedStore.updatePreferences { $0.requirementText = "不投示例甲科技" }
        try verify(!rejectedGreetingReloadedStore.allowsAutomaticResumeDelivery(
            accountID: rejectedGreetingAccount.id, conversationID: "boss-excluded-resume-conversation"
        ), "已建立会话的屏蔽企业仍可发送附件简历")
        rejectedGreetingReloadedStore.updatePreferences { $0.requirementText = previousRequirements }
        try verify(rejectedGreetingReloadedStore.allowsAutomaticResumeDelivery(
            accountID: rejectedGreetingAccount.id, conversationID: "boss-excluded-resume-conversation"
        ), "未命中排除项的会话被误拒")
        passed.append("latest requirements at greeting write boundary")
        try rejectedGreetingReloadedStore.markAutomaticGreetingWriteStarted(
            jobID: rejectedGreetingJob.id,
            at: rejectedGreetingNow.addingTimeInterval(11)
        )
        var crossedWriteBoundaryBlockedRelease = false
        do {
            try rejectedGreetingReloadedStore.releaseAutomaticGreetingReservationAfterDefinitiveRejection(
                jobID: rejectedGreetingJob.id
            )
        } catch BossAutomationError.operationNotReady {
            crossedWriteBoundaryBlockedRelease = true
        }
        try verify(
            crossedWriteBoundaryBlockedRelease &&
            rejectedGreetingReloadedStore.snapshot.jobs.first?.stage == .greetingDrafted &&
            rejectedGreetingReloadedStore.snapshot.automaticGreetingAttempts.first?.deliveryWriteStartedAt != nil &&
            rejectedGreetingReloadedStore.snapshot.automaticGreetingSafetyRecords.count == 1,
            "已跨过招聘方消息写入边界后错误释放了防重预留"
        )
        passed.append("definitive rejected greeting retry safety")

        let quotaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-GreetingQuota-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: quotaURL.deletingLastPathComponent()) }
        let quotaNow = Date(timeIntervalSince1970: 1_700_000_000)
        var quotaState = AppSnapshot()
        var quotaAccount = BossAccount(displayName: "配额账号")
        var quotaProfile = BossAccountProfile()
        quotaProfile.remoteID = "quota-identity"
        quotaAccount.remoteProfile = quotaProfile
        quotaAccount.loginStatus = .loggedIn
        var quotaAccountB = BossAccount(displayName: "配额账号 B")
        var quotaProfileB = BossAccountProfile()
        quotaProfileB.remoteID = "quota-identity-b"
        quotaAccountB.remoteProfile = quotaProfileB
        quotaAccountB.loginStatus = .loggedIn
        quotaState.accounts = [quotaAccount, quotaAccountB]
        quotaState.automation.dailyGreetingLimit = 150
        quotaState.automation.greetingIntervalSeconds = 300
        quotaState.automaticGreetingAttempts = (0..<149).map { index in
            AutomaticGreetingAttempt(
                accountID: quotaAccount.id,
                remoteIdentityID: quotaProfile.remoteID,
                remoteJobID: "quota-history-\(index)",
                attemptedAt: quotaNow.addingTimeInterval(-10 * 60),
                succeededAt: index == 0 ? quotaNow.addingTimeInterval(-9 * 60) : nil,
                confirmedMessageID: index == 0 ? "900001" : nil
            )
        }
        var quotaJob150 = JobListing(
            id: "quota-job-150",
            accountID: quotaAccount.id,
            title: "第 150 个岗位",
            company: "示例公司"
        )
        quotaJob150.description = "经 BOSS 详情接口返回的职位描述"
        quotaJob150.detailFetchedAt = quotaNow
        quotaJob150.remoteJobID = "quota-remote-150"
        quotaJob150.securityID = "quota-security-150"
        quotaJob150.listID = "quota-list-150"
        quotaJob150.stage = .recommended
        var quotaJob151 = quotaJob150
        quotaJob151.id = "quota-job-151"
        quotaJob151.remoteJobID = "quota-remote-151"
        quotaJob151.securityID = "quota-security-151"
        quotaJob151.listID = "quota-list-151"
        var quotaJobB = quotaJob150
        quotaJobB.id = "quota-job-b-1"
        quotaJobB.accountID = quotaAccountB.id
        quotaJobB.remoteJobID = "quota-remote-b-1"
        quotaJobB.securityID = "quota-security-b-1"
        quotaJobB.listID = "quota-list-b-1"
        quotaState.jobs = [quotaJob150, quotaJob151, quotaJobB]
        let quotaPersistence = JSONStatePersistence(fileURL: quotaURL)
        try quotaPersistence.save(quotaState)
        let quotaStore = AppStore(persistence: quotaPersistence)
        quotaStore.load()
        try verify(quotaStore.usedDailyGreetingQuotaToday(accountID: quotaAccount.id, now: quotaNow) == 149,
                   "尚未达到上限时额度占用未反映待确认的尝试")
        try quotaStore.prepareAutomaticGreeting(jobID: quotaJob150.id, now: quotaNow)
        var quota151Blocked = false
        do {
            try quotaStore.prepareAutomaticGreeting(
                jobID: quotaJob151.id,
                now: quotaNow.addingTimeInterval(10 * 60)
            )
        } catch BossAutomationError.operationNotReady {
            quota151Blocked = true
        }
        try quotaStore.prepareAutomaticGreeting(
            jobID: quotaJobB.id,
            now: quotaNow.addingTimeInterval(10 * 60)
        )
        let quotaNextDay = try required(
            Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: Calendar.current.startOfDay(for: quotaNow)
            ),
            "无法生成每日配额测试日期"
        )
        try verify(
            quotaStore.automaticGreetingCountToday(accountID: quotaAccount.id, now: quotaNow) == 150 &&
            quotaStore.usedDailyGreetingQuotaToday(accountID: quotaAccount.id, now: quotaNow) == 150 &&
            quotaStore.usedDailyGreetingQuotaToday(accountID: quotaAccount.id, now: quotaNextDay) == 0 &&
            quotaStore.automaticGreetingCountToday(
                accountID: quotaAccountB.id,
                now: quotaNow.addingTimeInterval(10 * 60)
            ) == 1 &&
            quotaStore.automaticGreetingCountToday(accountID: quotaAccount.id, now: quotaNextDay) == 0 &&
            quotaStore.confirmedAutomaticGreetingCountToday(accountID: quotaAccount.id, now: quotaNow) == 1 &&
            quotaStore.confirmedAutomaticGreetingCountToday(accountID: quotaAccount.id, now: quotaNextDay) == 0 &&
            quotaStore.confirmedAutomaticGreetingCountToday(now: quotaNow) == 1 &&
            quotaStore.confirmedAutomaticGreetingCountToday(now: quotaNextDay) == 0 &&
            quota151Blocked &&
            quotaStore.snapshot.automaticGreetingAttempts.count == 151 &&
            quotaStore.totalDailyGreetingLimit() == 300 &&
            quotaStore.hasQueuedAutomaticGreetingCandidate(accountID: quotaAccount.id) &&
            quotaStore.nextEligibleAutomaticGreetingAccountID(
                accountIDs: [quotaAccount.id],
                now: quotaNow
            ) == nil &&
            quotaStore.nextEligibleAutomaticGreetingAccountID(
                accountIDs: [quotaAccount.id],
                now: quotaNextDay
            ) == quotaAccount.id,
            "自动开聊成功数口径、单账号第 150/151 次边界或多账号配额隔离失效"
        )

        var overQuotaState = quotaState
        overQuotaState.automaticGreetingAttempts = [quotaState.automaticGreetingAttempts[0]]
        overQuotaState.dailyCommunicationRecords = (0..<155).map {
            AutomaticGreetingSafetyRecord(remoteIdentityID: quotaProfile.remoteID,
                                          remoteJobID: "quota-history-\($0)", attemptedAt: quotaNow)
        }
        let overQuotaPersistence = JSONStatePersistence(fileURL: quotaURL.deletingLastPathComponent().appendingPathComponent("over-quota.json"))
        try overQuotaPersistence.save(overQuotaState)
        let overQuotaStore = AppStore(persistence: overQuotaPersistence)
        overQuotaStore.load()
        var overQuotaBlocked = false
        do { try overQuotaStore.prepareAutomaticGreeting(jobID: quotaJob151.id, now: quotaNow) }
        catch BossAutomationError.operationNotReady { overQuotaBlocked = true }
        try verify(
            overQuotaStore.communicationCountToday(accountID: quotaAccount.id, now: quotaNow) == 155 &&
            overQuotaStore.confirmedAutomaticGreetingCountToday(accountID: quotaAccount.id, now: quotaNow) == 1 &&
            overQuotaStore.usedDailyGreetingQuotaToday(accountID: quotaAccount.id, now: quotaNow) == 150 &&
            overQuotaStore.usedDailyGreetingQuotaToday(accountID: quotaAccountB.id, now: quotaNow) == 0 &&
            overQuotaStore.usedDailyGreetingQuotaToday(accountID: UUID(), now: quotaNow) == 0 &&
            overQuotaStore.snapshot.automaticGreetingAttempts.count == 1 && overQuotaBlocked,
            "站内沟通总数被截断、被当作工具成功数，或超过上限后仍继续自动开聊"
        )
        passed.append("official counts remain truthful while automatic quota fails closed")

        let pacingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-GreetingInterval-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: pacingURL.deletingLastPathComponent()) }
        var pacingState = AppSnapshot()
        var pacingAccountA = BossAccount(displayName: "间隔账号 A")
        var pacingProfileA = BossAccountProfile()
        pacingProfileA.remoteID = "interval-identity-a"
        pacingAccountA.remoteProfile = pacingProfileA
        pacingAccountA.loginStatus = .loggedIn
        var pacingAccountB = BossAccount(displayName: "间隔账号 B")
        var pacingProfileB = BossAccountProfile()
        pacingProfileB.remoteID = "interval-identity-b"
        pacingAccountB.remoteProfile = pacingProfileB
        pacingAccountB.loginStatus = .loggedIn
        pacingState.accounts = [pacingAccountA, pacingAccountB]
        pacingState.automaticGreetingAttempts = [
            AutomaticGreetingAttempt(
                accountID: pacingAccountA.id,
                remoteIdentityID: pacingProfileA.remoteID,
                remoteJobID: "interval-history",
                attemptedAt: quotaNow
            )
        ]
        var pacingJob = JobListing(
            id: "interval-next-job",
            accountID: pacingAccountA.id,
            title: "间隔岗位",
            company: "示例公司"
        )
        pacingJob.description = "经 BOSS 详情接口返回的职位描述"
        pacingJob.detailFetchedAt = quotaNow
        pacingJob.remoteJobID = "interval-next-remote-job"
        pacingJob.securityID = "interval-next-security"
        pacingJob.listID = "interval-next-list"
        pacingJob.stage = .recommended
        var pacingJobB = pacingJob
        pacingJobB.id = "interval-next-job-b"
        pacingJobB.accountID = pacingAccountB.id
        pacingJobB.remoteJobID = "interval-next-remote-job-b"
        pacingJobB.securityID = "interval-next-security-b"
        pacingJobB.listID = "interval-next-list-b"
        pacingState.jobs = [pacingJob, pacingJobB]
        let pacingPersistence = JSONStatePersistence(fileURL: pacingURL)
        try pacingPersistence.save(pacingState)
        let pacingStore = AppStore(persistence: pacingPersistence)
        pacingStore.load()
        let pacingNextAllowedAt = try required(
            pacingStore.nextAutomaticGreetingAllowedAt(
                accountID: pacingAccountA.id,
                intervalSeconds: pacingStore.snapshot.automation.greetingIntervalSeconds
            ),
            "无法计算秒级自动开聊时间"
        )
        var earlyAttemptBlocked = false
        try verify(!pacingStore.hasAutomaticGreetingAttempt(accountID: pacingAccountA.id, remoteJobID: pacingJob.remoteJobID!),
                   "未尝试岗位错误命中缓存")
        do {
            try pacingStore.prepareAutomaticGreeting(
                jobID: pacingJob.id,
                now: pacingNextAllowedAt.addingTimeInterval(-1)
            )
        } catch BossAutomationError.operationNotReady {
            earlyAttemptBlocked = true
        }
        try pacingStore.prepareAutomaticGreeting(
            jobID: pacingJob.id,
            now: pacingNextAllowedAt
        )
        try verify(pacingStore.hasAutomaticGreetingAttempt(accountID: pacingAccountA.id, remoteJobID: pacingJob.remoteJobID!) &&
                   !pacingStore.hasAutomaticGreetingAttempt(accountID: pacingAccountB.id, remoteJobID: pacingJob.remoteJobID!),
                   "开聊缓存未随记录更新或跨身份串线")
        try pacingStore.prepareAutomaticGreeting(
            jobID: pacingJobB.id,
            now: quotaNow
        )
        try verify(
            earlyAttemptBlocked &&
            pacingNextAllowedAt.timeIntervalSince(quotaNow) >= 180 &&
            pacingNextAllowedAt.timeIntervalSince(quotaNow) <= 195 &&
            pacingStore.snapshot.automaticGreetingAttempts.count == 3 &&
            pacingStore.totalDailyGreetingLimit() == 300 &&
            (pacingStore.nextAutomaticGreetingAllowedAt(
                accountID: pacingAccountB.id,
                intervalSeconds: 30
            )?.timeIntervalSince(quotaNow) ?? 0) >= 30,
            "单账号抖动间隔、多账号独立开聊或动态总容量失效"
        )

        let fairnessURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-GreetingFairness-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: fairnessURL.deletingLastPathComponent()) }
        var fairnessState = AppSnapshot()
        var fairnessAccounts: [BossAccount] = []
        var fairnessJobs: [JobListing] = []
        for index in 0..<6 {
            var account = BossAccount(displayName: "公平账号 \(index + 1)")
            var profile = BossAccountProfile()
            profile.remoteID = "fairness-identity-\(index)"
            account.remoteProfile = profile
            fairnessAccounts.append(account)
            var job = JobListing(
                id: "fairness-job-\(index)",
                accountID: account.id,
                title: "公平岗位 \(index + 1)",
                company: "示例公司"
            )
            job.description = "经 BOSS 详情接口返回的职位描述"
            job.detailFetchedAt = quotaNow
            job.remoteJobID = "fairness-remote-job-\(index)"
            job.securityID = "fairness-security-\(index)"
            job.listID = "fairness-list-\(index)"
            job.stage = .recommended
            fairnessJobs.append(job)
            if index < 5 {
                fairnessState.automaticGreetingAttempts.append(
                    AutomaticGreetingAttempt(
                        accountID: account.id,
                        remoteIdentityID: profile.remoteID,
                        remoteJobID: "fairness-history-\(index)",
                        attemptedAt: quotaNow.addingTimeInterval(TimeInterval(index * 60))
                    )
                )
            }
        }
        fairnessState.accounts = fairnessAccounts
        fairnessState.jobs = fairnessJobs
        let fairnessPersistence = JSONStatePersistence(fileURL: fairnessURL)
        try fairnessPersistence.save(fairnessState)
        let fairnessStore = AppStore(persistence: fairnessPersistence)
        fairnessStore.load()
        try verify(
            fairnessStore.nextEligibleAutomaticGreetingAccountID(
                accountIDs: fairnessAccounts.map(\.id),
                now: quotaNow.addingTimeInterval(5 * 60)
            ) == fairnessAccounts[5].id,
            "固定账号顺序导致后续账号无法获得开聊机会"
        )
        passed.append("automatic greeting quota and intervals")
        let cascadeJob = JobListing(id: "cascade-job", accountID: accountA.id, title: "Java", company: "示例公司")
        cascadeStore.upsertJobs([cascadeJob])
        cascadeStore.createDraftAction(accountID: accountA.id, conversationID: nil, jobID: cascadeJob.id, kind: .sendGreeting, content: "草稿", reason: "测试")
        cascadeStore.removeJob(id: cascadeJob.id)
        try verify(cascadeStore.snapshot.jobs.isEmpty && cascadeStore.snapshot.pendingActions.isEmpty, "岗位删除未级联清理待办")
        var automaticGreetingJob = JobListing(id: "greeting-ledger-job", accountID: accountA.id, title: "Java", company: "示例公司")
        automaticGreetingJob.description = "经 BOSS 详情接口返回的职位描述"
        automaticGreetingJob.detailFetchedAt = quotaNow
        automaticGreetingJob.remoteJobID = "greeting-remote-job"
        automaticGreetingJob.stage = .recommended
        cascadeStore.upsertJobs([automaticGreetingJob])
        try cascadeStore.prepareAutomaticGreeting(jobID: automaticGreetingJob.id)
        let persistedGreetingState = try JSONStatePersistence(fileURL: cascadeURL).load()
        try verify(
            persistedGreetingState.jobs.first(where: { $0.id == automaticGreetingJob.id })?.stage == .greetingDrafted &&
            persistedGreetingState.automaticGreetingAttempts.count == 1 &&
            persistedGreetingState.activity.contains { $0.title == "自动打招呼已尝试" },
            "自动打招呼尝试未在外部写入前同步持久化"
        )
        try verify(
            !JobStage.greetingDrafted.countsAsOpenedChat &&
            JobStage.contacted.countsAsOpenedChat &&
            JobStage.resumeRequested.countsAsOpenedChat &&
            JobStage.resumeSent.countsAsOpenedChat,
            "未确认的开聊尝试被误计为已开聊"
        )
        automaticGreetingJob.description = "更新后的岗位证据"
        cascadeStore.upsertJobs([automaticGreetingJob])
        _ = cascadeStore.assessJobLocally(id: automaticGreetingJob.id)
        try verify(
            cascadeStore.snapshot.jobs.first(where: { $0.id == automaticGreetingJob.id })?.stage == .greetingDrafted,
            "岗位刷新或重新评估后已持久化的打招呼尝试被重置"
        )
        var accountBProfile = accountAProfile
        accountBProfile.remoteID = "greeting-identity-b"
        _ = try cascadeStore.applyBossProfile(accountBProfile, accountID: accountA.id)
        _ = try cascadeStore.applyBossProfile(accountAProfile, accountID: accountA.id)
        automaticGreetingJob.stage = .recommended
        cascadeStore.upsertJobs([automaticGreetingJob])
        var repeatedGreetingWasBlocked = false
        do {
            try cascadeStore.prepareAutomaticGreeting(jobID: automaticGreetingJob.id)
        } catch BossAutomationError.operationNotReady {
            repeatedGreetingWasBlocked = true
        }
        try verify(
            repeatedGreetingWasBlocked &&
            cascadeStore.snapshot.automaticGreetingAttempts.isEmpty &&
            cascadeStore.snapshot.automaticGreetingSafetyRecords.count == 1,
            "BOSS 身份 A→B→A 后绕过了自动打招呼一次性账本"
        )

        let ledgerMoveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-LedgerMove-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: ledgerMoveURL.deletingLastPathComponent()) }
        let ledgerMoveStore = AppStore(persistence: JSONStatePersistence(fileURL: ledgerMoveURL))
        let oldSlotID = ledgerMoveStore.addBossAccount()
        _ = try ledgerMoveStore.applyBossProfile(accountAProfile, accountID: oldSlotID)
        var movedJob = JobListing(id: "moved-ledger-job", accountID: oldSlotID, title: "Java", company: "示例公司")
        movedJob.description = "经 BOSS 详情接口返回的职位描述"
        movedJob.detailFetchedAt = quotaNow
        movedJob.remoteJobID = "moved-remote-job"
        movedJob.stage = .recommended
        ledgerMoveStore.upsertJobs([movedJob])
        try ledgerMoveStore.prepareAutomaticGreeting(jobID: movedJob.id)
        _ = try ledgerMoveStore.applyBossProfile(accountBProfile, accountID: oldSlotID)
        let newSlotID = ledgerMoveStore.addBossAccount()
        _ = try ledgerMoveStore.applyBossProfile(accountAProfile, accountID: newSlotID)
        try ledgerMoveStore.removeAccount(id: oldSlotID)
        movedJob.id = "moved-ledger-job-new-slot"
        movedJob.accountID = newSlotID
        movedJob.stage = .recommended
        ledgerMoveStore.upsertJobs([movedJob])
        var movedLedgerBlockedDuplicate = false
        do {
            try ledgerMoveStore.prepareAutomaticGreeting(jobID: movedJob.id)
        } catch BossAutomationError.operationNotReady {
            movedLedgerBlockedDuplicate = true
        }
        try verify(
            movedLedgerBlockedDuplicate &&
            ledgerMoveStore.snapshot.automaticGreetingAttempts.isEmpty &&
            ledgerMoveStore.snapshot.automaticGreetingSafetyRecords.count == 1,
            "远端身份迁移到新槽位后，删除旧槽位误删了自动开聊账本"
        )

        let reverseDeleteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-LedgerReverseDelete-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: reverseDeleteURL.deletingLastPathComponent()) }
        let reverseDeletePersistence = JSONStatePersistence(fileURL: reverseDeleteURL)
        let reverseDeleteStore = AppStore(persistence: reverseDeletePersistence)
        let previousIdentitySlotID = reverseDeleteStore.addBossAccount()
        _ = try reverseDeleteStore.applyBossProfile(accountAProfile, accountID: previousIdentitySlotID)
        var reverseDeleteJob = JobListing(
            id: "reverse-delete-ledger-job",
            accountID: previousIdentitySlotID,
            title: "Java",
            company: "示例公司"
        )
        reverseDeleteJob.description = "经 BOSS 详情接口返回的职位描述"
        reverseDeleteJob.detailFetchedAt = quotaNow
        reverseDeleteJob.remoteJobID = "reverse-delete-remote-job"
        reverseDeleteJob.stage = .recommended
        reverseDeleteStore.upsertJobs([reverseDeleteJob])
        let reverseDeletionAttemptTime = Date()
        try reverseDeleteStore.prepareAutomaticGreeting(
            jobID: reverseDeleteJob.id,
            now: reverseDeletionAttemptTime
        )
        _ = try reverseDeleteStore.applyBossProfile(accountBProfile, accountID: previousIdentitySlotID)
        let currentIdentitySlotID = reverseDeleteStore.addBossAccount()
        _ = try reverseDeleteStore.applyBossProfile(accountAProfile, accountID: currentIdentitySlotID)
        try verify(
            reverseDeleteStore.snapshot.automaticGreetingAttempts.isEmpty &&
            reverseDeleteStore.snapshot.automaticGreetingSafetyRecords.count == 1,
            "远端身份绑定新槽位后，自动开聊账本仍归属旧槽位"
        )
        try reverseDeleteStore.removeAccount(id: currentIdentitySlotID)
        try verify(
            reverseDeleteStore.snapshot.accounts.count == 1 &&
            reverseDeleteStore.snapshot.accounts.first?.id == previousIdentitySlotID &&
            reverseDeleteStore.snapshot.accounts.first?.remoteProfile?.remoteID == accountBProfile.remoteID &&
            !reverseDeleteStore.snapshot.automaticGreetingAttempts.contains {
                $0.remoteIdentityID == accountAProfile.remoteID
            },
            "删除远端身份的当前槽位后，仍残留该身份的自动开聊账本"
        )
        reverseDeleteStore.flush()
        let reloadedReverseDeleteStore = AppStore(persistence: reverseDeletePersistence)
        reloadedReverseDeleteStore.load()
        let encodedSafetyLedger = String(
            decoding: try JSONEncoder().encode(
                reloadedReverseDeleteStore.snapshot.automaticGreetingSafetyRecords
            ),
            as: UTF8.self
        )
        let restoredIdentitySlotID = reloadedReverseDeleteStore.addBossAccount()
        _ = try reloadedReverseDeleteStore.applyBossProfile(
            accountAProfile,
            accountID: restoredIdentitySlotID
        )
        var restoredIdentityJob = reverseDeleteJob
        restoredIdentityJob.id = "reverse-delete-restored-job"
        restoredIdentityJob.accountID = restoredIdentitySlotID
        restoredIdentityJob.stage = .recommended
        reloadedReverseDeleteStore.upsertJobs([restoredIdentityJob])
        var restoredIdentityDuplicateBlocked = false
        do {
            try reloadedReverseDeleteStore.prepareAutomaticGreeting(
                jobID: restoredIdentityJob.id,
                now: reverseDeletionAttemptTime.addingTimeInterval(10 * 60)
            )
        } catch BossAutomationError.operationNotReady {
            restoredIdentityDuplicateBlocked = true
        }
        try verify(
            restoredIdentityDuplicateBlocked &&
            reloadedReverseDeleteStore.automaticGreetingCountToday(
                accountID: restoredIdentitySlotID,
                now: reverseDeletionAttemptTime.addingTimeInterval(10 * 60)
            ) == 1 &&
            reloadedReverseDeleteStore.snapshot.automaticGreetingSafetyRecords.count == 1 &&
            !encodedSafetyLedger.contains(accountAProfile.remoteID) &&
            !encodedSafetyLedger.contains(reverseDeleteJob.remoteJobID ?? ""),
            "删除并重新添加同一 BOSS 身份后重置了每日配额或防重复记录"
        )

        let legacyLedgerDeleteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-LegacyLedgerDelete-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: legacyLedgerDeleteURL.deletingLastPathComponent()) }
        var legacyLedgerState = AppSnapshot()
        var legacyPreviousSlot = BossAccount(displayName: "旧槽位")
        legacyPreviousSlot.remoteProfile = accountBProfile
        var legacyCurrentSlot = BossAccount(displayName: "当前槽位")
        legacyCurrentSlot.remoteProfile = accountAProfile
        legacyLedgerState.accounts = [legacyPreviousSlot, legacyCurrentSlot]
        legacyLedgerState.automaticGreetingAttempts = [
            AutomaticGreetingAttempt(
                accountID: legacyPreviousSlot.id,
                remoteIdentityID: accountAProfile.remoteID,
                remoteJobID: "legacy-stale-owner-job"
            )
        ]
        let legacyLedgerPersistence = JSONStatePersistence(fileURL: legacyLedgerDeleteURL)
        try legacyLedgerPersistence.save(legacyLedgerState)
        let legacyLedgerDeleteStore = AppStore(persistence: legacyLedgerPersistence)
        legacyLedgerDeleteStore.load()
        try legacyLedgerDeleteStore.removeAccount(id: legacyCurrentSlot.id)
        legacyLedgerDeleteStore.flush()
        let persistedLegacyLedgerDeleteStore = AppStore(persistence: legacyLedgerPersistence)
        persistedLegacyLedgerDeleteStore.load()
        try verify(
            persistedLegacyLedgerDeleteStore.snapshot.accounts.count == 1 &&
            persistedLegacyLedgerDeleteStore.snapshot.accounts.first?.id == legacyPreviousSlot.id &&
            !persistedLegacyLedgerDeleteStore.snapshot.automaticGreetingAttempts.contains {
                $0.remoteIdentityID == accountAProfile.remoteID
            } &&
            !persistedLegacyLedgerDeleteStore.snapshot.automaticGreetingAttempts.contains {
                $0.accountID == legacyCurrentSlot.id
            },
            "删除当前远端身份槽位后，旧版错位归属的自动开聊账本仍残留"
        )
        cascadeStore.removeJob(id: automaticGreetingJob.id)
        let cascadeSummary = BossFriendSummary(
            conversationID: "cascade-conversation",
            recruiterName: "招聘方",
            company: "示例公司",
            jobTitle: "Java",
            latestText: "您好",
            unreadCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            securityID: "security",
            listID: "list",
            latestIsIncoming: true
        )
        _ = cascadeStore.upsertBossFriendSummaries([cascadeSummary], accountID: accountA.id)
        let cascadeConversation = try required(cascadeStore.snapshot.conversations.first, "BOSS 会话摘要写入失败")
        cascadeStore.createDraftAction(accountID: accountA.id, conversationID: cascadeConversation.id, jobID: nil, kind: .sendMessage, content: "回复", reason: "测试")
        cascadeStore.removeConversation(id: cascadeConversation.id)
        try verify(cascadeStore.snapshot.conversations.isEmpty && cascadeStore.snapshot.pendingActions.isEmpty, "会话删除未级联清理待办")
        cascadeStore.addAccount(named: "账号 B")
        let accountB = try required(cascadeStore.snapshot.accounts.last, "第二个账号创建失败")
        try cascadeStore.removeAccount(id: accountB.id)
        try verify(cascadeStore.selectedAccountID == accountA.id && cascadeStore.snapshot.accounts.count == 1, "账号删除后选择未协调")
        try cascadeStore.beginAccountDeletion(id: accountA.id)
        let pendingDeletionState = try JSONStatePersistence(fileURL: cascadeURL).load()
        try verify(pendingDeletionState.accounts.first?.status == .deleting, "待删除账号状态未在清理前同步持久化")
        cascadeStore.flush()
        passed.append("destructive cascades")

        // 号码由合成片段组成，仅用于验证脱敏规则。
        let fixturePhone = "199" + String(repeating: "0", count: 8)
        let fixtureIdentity = "110101" + "19000101" + "0000"
        let fixtureEmail = "candidate@example.invalid"
        let sensitive = "联系 \(fixturePhone)，\(fixtureEmail)，\(fixtureIdentity)"
        let redacted = PrivacyRedactor.redact(sensitive, limit: 1_000)
        try verify(!redacted.contains(fixturePhone) && !redacted.contains(fixtureEmail) && !redacted.contains(fixtureIdentity), "Codex 输入脱敏失败")
        passed.append("privacy redaction")
        let legacyBodyPermission = Data(#"{"allowJobDataToCodex":true,"allowFullResumeTextToCodex":true,"model":"fixture-model"}"#.utf8)
        let privacyConfiguration = try JSONDecoder().decode(CodexConfiguration.self, from: legacyBodyPermission)
        let privacyConfigurationJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(privacyConfiguration)) as? [String: Any]
        try verify(privacyConfiguration.allowJobDataToCodex && privacyConfiguration.model == "fixture-model" &&
                   privacyConfigurationJSON?["allowFullResumeTextToCodex"] == nil,
                   "旧版正文授权未移除或影响了其他 Codex 配置")
        var analysisConfiguration = CodexConfiguration()
        try verify(!analysisConfiguration.allowJobDataToCodex,
                   "新配置默认开放了岗位数据授权")
        analysisConfiguration.setAnalysisEnabled(true, for: \.enableJobAssessment)
        try verify(analysisConfiguration.allowJobDataToCodex && analysisConfiguration.enableJobAssessment &&
                   !analysisConfiguration.enableReplyDrafting, "开启岗位评估同时开放了未授权的消息分析")
        analysisConfiguration.setAnalysisEnabled(true, for: \.enableReplyDrafting)
        analysisConfiguration.setAnalysisEnabled(false, for: \.enableJobAssessment)
        try verify(analysisConfiguration.allowJobDataToCodex && !analysisConfiguration.enableJobAssessment &&
                   analysisConfiguration.enableReplyDrafting, "关闭岗位评估影响了已开启的消息分析")
        analysisConfiguration.setAnalysisEnabled(false, for: \.enableReplyDrafting)
        try verify(!analysisConfiguration.allowJobDataToCodex && !analysisConfiguration.enableJobAssessment &&
                   !analysisConfiguration.enableReplyDrafting, "关闭所有分析后仍保留岗位数据授权")
        let deniedLegacyAnalysis = Data(#"{"allowJobDataToCodex":false,"enableJobAssessment":true,"enableReplyDrafting":true}"#.utf8)
        var deniedConfiguration = try JSONDecoder().decode(CodexConfiguration.self, from: deniedLegacyAnalysis)
        deniedConfiguration.setAnalysisEnabled(true, for: \.enableReplyDrafting)
        let restoredAnalysis = try JSONDecoder().decode(CodexConfiguration.self, from: JSONEncoder().encode(deniedConfiguration))
        try verify(restoredAnalysis.allowJobDataToCodex && restoredAnalysis.enableReplyDrafting &&
                   !restoredAnalysis.enableJobAssessment, "旧版授权迁移或重启后扩大了分析能力")
        passed.append("analysis feature toggles preserve denied permissions and authorize only selected capabilities")
        var privateResume = ResumeProfile(text: "RAW_RESUME_BODY_MUST_NOT_BE_SENT", skills: ["Java"], yearsOfExperience: 6)
        let fallbackSummary = PrivacyRedactor.resumeSummary(privateResume)
        privateResume.profileSummary = "Java 应用研发画像"
        let profileOnlySummary = PrivacyRedactor.resumeSummary(privateResume)
        try verify(fallbackSummary.contains("Java") && fallbackSummary.contains("6") &&
                   profileOnlySummary.contains("Java 应用研发画像") &&
                   !fallbackSummary.contains(privateResume.text) && !profileOnlySummary.contains(privateResume.text),
                   "画像摘要或无画像的回退路径仍附带简历正文")
        try verify(cascadeStore.localStateURL == cascadeURL, "设置中的数据路径未使用当前持久化目录")
        passed.append("retired resume-body permission and profile-only Codex summaries")

        let legacyRemoteOnlyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-RemoteOnlyMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: legacyRemoteOnlyURL.deletingLastPathComponent()) }
        var legacyRemoteOnlyState = AppSnapshot()
        legacyRemoteOnlyState.schemaVersion = 1
        var legacyRemoteAccount = BossAccount(displayName: "旧版账号")
        var legacyRemoteProfile = BossAccountProfile()
        legacyRemoteProfile.remoteID = "legacy-verified-geek"
        legacyRemoteProfile.name = "旧版账号"
        legacyRemoteAccount.remoteProfile = legacyRemoteProfile
        legacyRemoteOnlyState.accounts = [legacyRemoteAccount]
        let legacyThrottleAt = Date().addingTimeInterval(-5 * 60)
        legacyRemoteOnlyState.activity = [
            ActivityEntry(
                accountID: legacyRemoteAccount.id,
                level: .error,
                title: "BOSS 本次任务失败",
                detail: "BOSS 已触发限速，本账号暂停自动访问。",
                createdAt: legacyThrottleAt
            )
        ]
        legacyRemoteOnlyState.resume.text = "旧版手填简历正文"
        legacyRemoteOnlyState.resume.targetRoles = ["旧版目标岗位"]
        legacyRemoteOnlyState.automation.mode = .automatic
        legacyRemoteOnlyState.automation.workerEnabled = true
        let legacyManualJob = JobListing(
            id: "manual-job",
            accountID: legacyRemoteAccount.id,
            title: "手填岗位",
            company: "手填公司"
        )
        var legacyBossJob = JobListing(
            id: "boss-remote-job",
            accountID: legacyRemoteAccount.id,
            title: "远端岗位",
            company: "远端公司"
        )
        legacyBossJob.remoteJobID = "remote-job"
        legacyBossJob.stage = .resumeSent
        legacyRemoteOnlyState.jobs = [legacyManualJob, legacyBossJob]
        let migrationMessage = ChatMessage(
            id: "message",
            direction: .incoming,
            text: "您好",
            sentAt: Date(),
            intent: nil,
            confidence: nil
        )
        let legacyManualConversation = Conversation(
            id: "manual-conversation",
            accountID: legacyRemoteAccount.id,
            recruiterName: "手填招聘方",
            company: "手填公司",
            jobTitle: "手填岗位",
            messages: [migrationMessage],
            unreadCount: 1,
            lastSyncedAt: Date(),
            sourceURL: ""
        )
        var legacyBossConversation = legacyManualConversation
        legacyBossConversation.id = "boss-remote-conversation"
        legacyBossConversation.remoteConversationID = "remote-conversation"
        legacyRemoteOnlyState.conversations = [legacyManualConversation, legacyBossConversation]
        legacyRemoteOnlyState.pendingActions = [
            PendingAction(
                accountID: legacyRemoteAccount.id,
                jobID: legacyManualJob.id,
                kind: .sendGreeting,
                content: "手填草稿",
                reason: "旧版"
            ),
            PendingAction(
                accountID: legacyRemoteAccount.id,
                jobID: legacyBossJob.id,
                kind: .sendGreeting,
                content: "远端草稿",
                reason: "保留"
            )
        ]
        let legacyRemoteOnlyPersistence = JSONStatePersistence(fileURL: legacyRemoteOnlyURL)
        try legacyRemoteOnlyPersistence.save(legacyRemoteOnlyState)
        let migratedRemoteOnlyStore = AppStore(persistence: legacyRemoteOnlyPersistence)
        migratedRemoteOnlyStore.load()
        try verify(
            migratedRemoteOnlyStore.snapshot.schemaVersion == 25 &&
            migratedRemoteOnlyStore.snapshot.resume.targetRoles.isEmpty &&
            !migratedRemoteOnlyStore.snapshot.resume.hasStoredAttachment &&
            !migratedRemoteOnlyStore.snapshot.resume.isReady &&
            migratedRemoteOnlyStore.snapshot.resume.skills.isEmpty &&
            migratedRemoteOnlyStore.snapshot.resume.yearsOfExperience == 0 &&
            !migratedRemoteOnlyStore.snapshot.automation.workerEnabled &&
            migratedRemoteOnlyStore.snapshot.jobs.map(\.id) == [legacyBossJob.id] &&
            migratedRemoteOnlyStore.snapshot.jobs.first?.stage == .discovered &&
            migratedRemoteOnlyStore.snapshot.conversations.map(\.id) == [legacyBossConversation.id] &&
            migratedRemoteOnlyStore.snapshot.pendingActions.map(\.jobID) == [legacyBossJob.id] &&
            migratedRemoteOnlyStore.snapshot.automation.dailyGreetingLimit == 150 &&
            migratedRemoteOnlyStore.snapshot.automation.greetingIntervalSeconds == 180,
            "旧版手填状态未迁移为仅保留 BOSS 远端记录"
        )
        passed.append("remote-only state migration")

        let conservativeMigrationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-ConservativeMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: conservativeMigrationURL.deletingLastPathComponent()) }
        var conservativeMigrationState = AppSnapshot()
        conservativeMigrationState.schemaVersion = 4
        conservativeMigrationState.automation.dailyGreetingLimit = 10
        conservativeMigrationState.automation.greetingIntervalSeconds = 60
        let conservativeMigrationAccount = BossAccount(displayName: "保守迁移账号")
        conservativeMigrationState.accounts = [conservativeMigrationAccount]
        let conservativeMigrationPersistence = JSONStatePersistence(fileURL: conservativeMigrationURL)
        try conservativeMigrationPersistence.save(conservativeMigrationState)
        var conservativeJSON = try required(
            JSONSerialization.jsonObject(with: Data(contentsOf: conservativeMigrationURL)) as? [String: Any],
            "无法构造旧版冷却迁移样本"
        )
        var conservativeAccounts = try required(
            conservativeJSON["accounts"] as? [[String: Any]],
            "旧版迁移样本缺少账号"
        )
        conservativeAccounts[0]["connectorCooldownUntil"] = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(20 * 60)
        )
        conservativeJSON["accounts"] = conservativeAccounts
        try JSONSerialization.data(withJSONObject: conservativeJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: conservativeMigrationURL, options: .atomic)
        let conservativeMigrationStore = AppStore(persistence: conservativeMigrationPersistence)
        conservativeMigrationStore.load()
        let conservativeMigratedJSON = String(
            decoding: try Data(contentsOf: conservativeMigrationURL),
            as: UTF8.self
        )
        try verify(
            conservativeMigrationStore.snapshot.schemaVersion == 25 &&
            conservativeMigrationStore.snapshot.automation.dailyGreetingLimit == 150 &&
            conservativeMigrationStore.snapshot.automation.greetingIntervalSeconds == 180 &&
            !conservativeMigratedJSON.contains("connectorCooldownUntil"),
            "schema 11 迁移未保留外发节奏或未清理旧冷却字段"
        )
        passed.append("legacy cooldown removal migration")

        let secondBasedPacingMigrationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-SecondBasedPacingMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: secondBasedPacingMigrationURL.deletingLastPathComponent()) }
        var secondBasedPacingMigrationState = AppSnapshot()
        secondBasedPacingMigrationState.schemaVersion = 17
        secondBasedPacingMigrationState.automation.greetingIntervalSeconds = 60
        let secondBasedPacingMigrationPersistence = JSONStatePersistence(
            fileURL: secondBasedPacingMigrationURL
        )
        try secondBasedPacingMigrationPersistence.save(secondBasedPacingMigrationState)
        let secondBasedPacingMigrationStore = AppStore(
            persistence: secondBasedPacingMigrationPersistence
        )
        secondBasedPacingMigrationStore.load()
        try verify(
            secondBasedPacingMigrationStore.snapshot.schemaVersion == 25 &&
            secondBasedPacingMigrationStore.snapshot.automation.greetingIntervalSeconds == 180,
            "schema 21 未把旧版秒级间隔迁移为保守默认值"
        )

        let searchFrequencyMigrationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-SearchFrequencyMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: searchFrequencyMigrationURL.deletingLastPathComponent()) }
        var searchFrequencyMigrationState = AppSnapshot()
        searchFrequencyMigrationState.schemaVersion = 18
        searchFrequencyMigrationState.automation.searchIntervalMinutes = 15
        let searchFrequencyMigrationPersistence = JSONStatePersistence(
            fileURL: searchFrequencyMigrationURL
        )
        try searchFrequencyMigrationPersistence.save(searchFrequencyMigrationState)
        let searchFrequencyMigrationStore = AppStore(
            persistence: searchFrequencyMigrationPersistence
        )
        searchFrequencyMigrationStore.load()
        try verify(
            searchFrequencyMigrationStore.snapshot.schemaVersion == 25 &&
            searchFrequencyMigrationStore.snapshot.automation.searchIntervalMinutes == 60,
            "schema 21 未把旧版高频搜索迁移为 60 分钟"
        )

        let explicitPacingMigrationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-ExplicitPacingMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: explicitPacingMigrationURL.deletingLastPathComponent()) }
        var explicitPacingMigrationState = AppSnapshot()
        explicitPacingMigrationState.schemaVersion = 15
        explicitPacingMigrationState.automation.greetingIntervalSeconds = 300
        let explicitPacingMigrationPersistence = JSONStatePersistence(fileURL: explicitPacingMigrationURL)
        try explicitPacingMigrationPersistence.save(explicitPacingMigrationState)
        let explicitPacingMigrationStore = AppStore(persistence: explicitPacingMigrationPersistence)
        explicitPacingMigrationStore.load()
        try verify(
            explicitPacingMigrationStore.snapshot.schemaVersion == 25 &&
            explicitPacingMigrationStore.snapshot.automation.greetingIntervalSeconds == 180,
            "schema 21 未收紧旧版最低开聊间隔"
        )

        let safetyUpgradeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-SafetyUpgrade-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: safetyUpgradeURL.deletingLastPathComponent()) }
        let safetyUpgradePersistence = JSONStatePersistence(fileURL: safetyUpgradeURL)
        var safetyUpgradeState = quotaState
        safetyUpgradeState.schemaVersion = 24
        safetyUpgradeState.automation.workerEnabled = true
        safetyUpgradeState.automation.dailyGreetingLimit = 150
        safetyUpgradeState.automation.greetingIntervalSeconds = 30
        safetyUpgradeState.automation.monitorIntervalMinutes = 30
        safetyUpgradeState.automation.searchIntervalMinutes = 30
        safetyUpgradeState.automation.safetyCooldownUntil = longerRiskCooldown
        try safetyUpgradePersistence.save(safetyUpgradeState)
        let safetyUpgradeBefore = try safetyUpgradePersistence.load()
        let safetyUpgradeStore = AppStore(persistence: safetyUpgradePersistence)
        safetyUpgradeStore.load()
        try verify(
            safetyUpgradeStore.snapshot.schemaVersion == 25 &&
            !safetyUpgradeStore.snapshot.automation.workerEnabled &&
            safetyUpgradeStore.snapshot.automation.dailyGreetingLimit == 150 &&
            safetyUpgradeStore.snapshot.automation.greetingIntervalSeconds == 180 &&
            safetyUpgradeStore.snapshot.automation.monitorIntervalMinutes == 60 &&
            safetyUpgradeStore.snapshot.automation.searchIntervalMinutes == 60 &&
            safetyUpgradeStore.snapshot.automation.safetyCooldownUntil == longerRiskCooldown &&
            safetyUpgradeStore.snapshot.accounts == safetyUpgradeBefore.accounts &&
            safetyUpgradeStore.snapshot.jobs == safetyUpgradeBefore.jobs &&
            safetyUpgradeStore.snapshot.automaticGreetingAttempts == safetyUpgradeBefore.automaticGreetingAttempts,
            "schema 25 未保留 150 次每日上限、降低请求频率或保护账号、岗位、冷却和防重账本"
        )
        safetyUpgradeState.automation.dailyGreetingLimit = 10
        safetyUpgradeState.automation.greetingIntervalSeconds = 600
        safetyUpgradeState.automation.monitorIntervalMinutes = 90
        safetyUpgradeState.automation.searchIntervalMinutes = 120
        try safetyUpgradePersistence.save(safetyUpgradeState)
        let slowerUpgradeStore = AppStore(persistence: safetyUpgradePersistence)
        slowerUpgradeStore.load()
        try verify(
            slowerUpgradeStore.snapshot.automation.dailyGreetingLimit == 10 &&
            slowerUpgradeStore.snapshot.automation.greetingIntervalSeconds == 600 &&
            slowerUpgradeStore.snapshot.automation.monitorIntervalMinutes == 90 &&
            slowerUpgradeStore.snapshot.automation.searchIntervalMinutes == 120,
            "schema 25 覆盖了用户更保守的节奏"
        )
        passed.append("conservative upgrade preserves stricter settings and safety data")

        let legacyMissingLimitData = Data(
            """
            {
              "schemaVersion": 4,
              "automation": {
                "workerEnabled": true,
                "automaticallySendGreetings": true
              }
            }
            """.utf8
        )
        let legacyMissingLimitSnapshot = try JSONDecoder().decode(
            AppSnapshot.self,
            from: legacyMissingLimitData
        )
        let legacyMissingAutomationSnapshot = try JSONDecoder().decode(
            AppSnapshot.self,
            from: Data("{\"schemaVersion\":4}".utf8)
        )
        try verify(
            legacyMissingLimitSnapshot.automation.dailyGreetingLimit == 10 &&
            legacyMissingAutomationSnapshot.automation.dailyGreetingLimit == 10,
            "缺少旧版外发上限字段时未保留旧版默认值"
        )
        passed.append("legacy missing greeting limit migration")

        let orphanAttemptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-OrphanAttemptMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: orphanAttemptURL.deletingLastPathComponent()) }
        var orphanAttemptState = AppSnapshot()
        orphanAttemptState.schemaVersion = 5
        orphanAttemptState.automaticGreetingAttempts = [
            AutomaticGreetingAttempt(
                accountID: UUID(),
                remoteIdentityID: "removed-raw-identity",
                remoteJobID: "removed-raw-job"
            )
        ]
        let orphanAttemptPersistence = JSONStatePersistence(fileURL: orphanAttemptURL)
        try orphanAttemptPersistence.save(orphanAttemptState)
        let orphanAttemptStore = AppStore(persistence: orphanAttemptPersistence)
        orphanAttemptStore.load()
        let encodedOrphanSafety = String(
            decoding: try JSONEncoder().encode(
                orphanAttemptStore.snapshot.automaticGreetingSafetyRecords
            ),
            as: UTF8.self
        )
        try verify(
            orphanAttemptStore.snapshot.schemaVersion == 25 &&
            orphanAttemptStore.snapshot.automaticGreetingAttempts.isEmpty &&
            orphanAttemptStore.snapshot.automaticGreetingSafetyRecords.count == 1 &&
            !encodedOrphanSafety.contains("removed-raw-identity") &&
            !encodedOrphanSafety.contains("removed-raw-job"),
            "旧版孤儿外发记录未匿名化或仍保留原始远端标识"
        )
        passed.append("orphan greeting attempt migration")

        var challengedAccount = BossAccount(displayName: "待本人验证账号")
        challengedAccount.manualVerificationChallenge = BossManualVerificationChallenge(
            code: 36,
            operation: "岗位检索",
            message: "需要安全验证",
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let unchallengedAccount = BossAccount(displayName: "正常账号")
        let challengedStateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-VerificationMigration-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: challengedStateURL.deletingLastPathComponent()) }
        var challengedState = AppSnapshot()
        challengedState.schemaVersion = 21
        challengedState.accounts = [challengedAccount]
        let challengedPersistence = JSONStatePersistence(fileURL: challengedStateURL)
        try challengedPersistence.save(challengedState)
        let challengedStore = AppStore(persistence: challengedPersistence)
        challengedStore.load()
        let scheduleEligibleAccounts = BossAutomationController.workerScheduleEligibleAccounts([
            challengedAccount,
            unchallengedAccount
        ])
        let configuredAutomaticAccounts = BossAutomationController.workerConfiguredAccounts([
            challengedAccount,
            unchallengedAccount
        ])
        let credentialObservedAfterChallenge = BossCredential(
            cookies: [bossCookie, secureCookie, stokenCookie, wbgCookie],
            savedAt: Date(timeIntervalSince1970: 1_700_003_600)
        )
        try verify(
            challengedStore.snapshot.schemaVersion == 25 &&
            challengedStore.snapshot.accounts.first?.manualVerificationChallenge == nil &&
            credentialObservedAfterChallenge.isAutomationReady &&
            credentialObservedAfterChallenge.savedAt > challengedAccount.manualVerificationChallenge!.detectedAt &&
            BossManualVerificationGate.allowsAutomaticWork(for: challengedAccount) &&
            BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: challengedAccount) &&
            BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: unchallengedAccount) &&
            scheduleEligibleAccounts.map(\.id) == [challengedAccount.id, unchallengedAccount.id] &&
            configuredAutomaticAccounts.map(\.id) == [challengedAccount.id, unchallengedAccount.id] &&
            !BossManualVerificationGate.shouldClear(
                challenge: challengedAccount.manualVerificationChallenge,
                explicitRecheckRequested: false,
                authoritativeProfileReadSucceeded: true
            ) &&
            !BossManualVerificationGate.shouldClear(
                challenge: challengedAccount.manualVerificationChallenge,
                explicitRecheckRequested: true,
                authoritativeProfileReadSucceeded: false
            ) &&
            !BossManualVerificationGate.shouldClear(
                challenge: challengedAccount.manualVerificationChallenge,
                explicitRecheckRequested: true,
                authoritativeProfileReadSucceeded: true
            ) &&
            !BossManualVerificationGate.allowsAuthoritativeProfileRead(
                connectorReadsEnabled: false,
                explicitRecheckRequested: false
            ) &&
            BossManualVerificationGate.allowsAuthoritativeProfileRead(
                connectorReadsEnabled: false,
                explicitRecheckRequested: true
            ) &&
            BossManualVerificationGate.allowsAuthoritativeProfileRead(
                connectorReadsEnabled: true,
                explicitRecheckRequested: false
            ),
            "schema 22 未清理旧人工验证锁，或请求级验证错误仍阻止账号调度"
        )
        passed.append("boss manual verification lock removal")

        let ordinaryErrorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-NoInferredCooldown-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: ordinaryErrorURL.deletingLastPathComponent()) }
        var ordinaryErrorState = AppSnapshot()
        ordinaryErrorState.schemaVersion = 6
        let ordinaryErrorAccount = BossAccount(displayName: "普通错误账号")
        ordinaryErrorState.accounts = [ordinaryErrorAccount]
        ordinaryErrorState.activity = [
            ActivityEntry(
                accountID: ordinaryErrorAccount.id,
                level: .error,
                title: "BOSS 本次任务失败",
                detail: "普通上游参数错误，文本即使出现异常行为或限速字样也只是本次失败。"
            )
        ]
        let ordinaryErrorPersistence = JSONStatePersistence(fileURL: ordinaryErrorURL)
        try ordinaryErrorPersistence.save(ordinaryErrorState)
        let ordinaryErrorStore = AppStore(persistence: ordinaryErrorPersistence)
        ordinaryErrorStore.load()
        try verify(
            ordinaryErrorStore.snapshot.schemaVersion == 25 &&
            ordinaryErrorStore.snapshot.accounts.first?.status == .active &&
            ordinaryErrorStore.snapshot.activity.first?.detail.contains("本次失败") == true,
            "普通错误记录在升级后改变了账号运行状态"
        )
        passed.append("ordinary errors remain request scoped")

        let manualTime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let manualRows: [[String: Any]] = [
            ["encryptJobId": "manual-role", "happenTime": manualTime.timeIntervalSince1970 * 1000, "hasContact": 0],
            ["encryptJobId": "tool-role", "happenTime": manualTime.addingTimeInterval(-1).timeIntervalSince1970 * 1000, "hasContact": 1]
        ]
        let parsedDaily = try BossPayloadParser.dailyInteractions(
            from: ["cardList": manualRows, "hasMore": false], remoteIdentityID: "manual-account"
        )
        try verify(parsedDaily.records.count == 2 && !parsedDaily.hasMore, "官方沟通列表未正确解析")
        for invalid: Any in [
            ["cardList": [], "hasMore": true],
            ["cardList": [["encryptJobId": "bad", "happenTime": true, "hasContact": 1]], "hasMore": false],
            ["cardList": Array(manualRows.reversed()), "hasMore": false],
            ["cardList": [["encryptJobId": "bad", "happenTime": -1, "hasContact": 1]], "hasMore": false]
        ] {
            var blocked = false
            do { _ = try BossPayloadParser.dailyInteractions(from: invalid, remoteIdentityID: "manual-account") }
            catch BossAPIError.invalidPayload { blocked = true }
            try verify(blocked, "异常每日统计被当作空额度")
        }
        let manualURL = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-ManualQuota-\(UUID())/state.json")
        defer { try? FileManager.default.removeItem(at: manualURL.deletingLastPathComponent()) }
        let manualPersistence = JSONStatePersistence(fileURL: manualURL)
        var manualState = AppSnapshot()
        var manualAccount = BossAccount(displayName: "手动统计")
        var manualProfile = BossAccountProfile()
        manualProfile.remoteID = "manual-account"
        manualAccount.remoteProfile = manualProfile
        manualAccount.loginStatus = .loggedIn
        manualState.accounts = [manualAccount]
        manualState.automaticGreetingAttempts = [AutomaticGreetingAttempt(
            accountID: manualAccount.id, remoteIdentityID: manualProfile.remoteID,
            remoteJobID: "tool-role", attemptedAt: manualTime,
            succeededAt: manualTime, confirmedMessageID: "10001"
        )]
        var manualToolDelivery = confirmedPromotedDelivery
        manualToolDelivery.accountID = manualAccount.id
        manualToolDelivery.remoteIdentityID = manualProfile.remoteID
        manualToolDelivery.serverAcceptedAt = manualTime
        manualToolDelivery.verifiedAt = manualTime
        manualState.resumeDeliveryRecords = [manualToolDelivery]
        try manualPersistence.save(manualState)
        let manualStore = AppStore(persistence: manualPersistence)
        manualStore.load()
        manualStore.recordDailyCommunications(parsedDaily.records + parsedDaily.records, now: manualTime)
        manualStore.completeDailyCommunicationSync(remoteIdentityID: manualProfile.remoteID, startedAt: manualTime)
        try verify(
            manualStore.communicationCountToday(now: manualTime) == 2 &&
            manualStore.automaticGreetingCountToday(accountID: manualAccount.id, now: manualTime) == 2 &&
            manualStore.confirmedAutomaticGreetingCountToday(accountID: manualAccount.id, now: manualTime) == 1 &&
            manualStore.hasAutomaticGreetingAttempt(accountID: manualAccount.id, remoteJobID: "manual-role") &&
            manualStore.dailyCommunicationLastSyncedAt(accountID: manualAccount.id, now: manualTime) == manualTime,
            "手动与工具计数未合并去重或未阻止重复开聊"
        )
        try verify(manualStore.resumeExchangeCountToday(now: manualTime) == 1, "工具交换统计回退失败")
        manualStore.recordDailyResumeExchanges(parsedDaily.records + parsedDaily.records + [
            AutomaticGreetingSafetyRecord(remoteIdentityID: manualProfile.remoteID, remoteJobID: "yesterday", attemptedAt: Calendar.current.startOfDay(for: manualTime).addingTimeInterval(-1)),
            AutomaticGreetingSafetyRecord(remoteIdentityID: manualProfile.remoteID, remoteJobID: "future", attemptedAt: manualTime.addingTimeInterval(60))
        ], now: manualTime)
        manualStore.completeDailyResumeExchangeSync(remoteIdentityID: manualProfile.remoteID, startedAt: manualTime)
        try verify(
            manualStore.resumeExchangeCountToday(now: manualTime) == 2 &&
            manualStore.dailyResumeExchangeLastSyncedAt(accountID: manualAccount.id, now: manualTime) == manualTime,
            "手动与工具交换未统一按官方投递记录去重，或重复叠加工具账本"
        )
        let manualReloaded = AppStore(persistence: manualPersistence)
        manualReloaded.load()
        let nextManualDay = Calendar.current.startOfDay(for: manualTime).addingTimeInterval(86_400)
        try verify(
            manualReloaded.communicationCountToday(now: manualTime) == 2 &&
            manualReloaded.resumeExchangeCountToday(now: manualTime) == 2 &&
            manualReloaded.resumeExchangeCountToday(now: nextManualDay) == 0 &&
            manualReloaded.dailyResumeExchangeLastSyncedAt(accountID: manualAccount.id, now: nextManualDay) == nil &&
            manualReloaded.automaticGreetingCountToday(accountID: manualAccount.id, now: nextManualDay) == 0 &&
            manualReloaded.dailyCommunicationLastSyncedAt(accountID: manualAccount.id, now: nextManualDay) == nil,
            "手动计数持久化或跨日重置失败"
        )
        passed.append("manual and automatic communication quota union")
        passed.append("manual and automatic resume exchange statistics")

        let scopedURL = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-ScopedStatistics-\(UUID())/state.json")
        defer { try? FileManager.default.removeItem(at: scopedURL.deletingLastPathComponent()) }
        let scopedPersistence = JSONStatePersistence(fileURL: scopedURL)
        var scopedState = manualState
        var otherStatisticsAccount = BossAccount(displayName: "第二个统计账号")
        var otherStatisticsProfile = BossAccountProfile()
        otherStatisticsProfile.remoteID = "other-statistics-account"
        otherStatisticsAccount.remoteProfile = otherStatisticsProfile
        otherStatisticsAccount.loginStatus = .loggedIn
        let unboundStatisticsAccount = BossAccount(displayName: "未绑定统计账号")
        scopedState.accounts += [otherStatisticsAccount, unboundStatisticsAccount]
        scopedState.automaticGreetingAttempts.append(AutomaticGreetingAttempt(
            accountID: otherStatisticsAccount.id, remoteIdentityID: otherStatisticsProfile.remoteID,
            remoteJobID: "tool-role", attemptedAt: manualTime,
            succeededAt: manualTime, confirmedMessageID: "20001"
        ))
        var otherToolDelivery = manualToolDelivery
        otherToolDelivery.accountID = otherStatisticsAccount.id
        otherToolDelivery.remoteIdentityID = otherStatisticsProfile.remoteID
        otherToolDelivery.id = ResumeDeliveryRecord.identifier(
            remoteIdentityID: otherToolDelivery.remoteIdentityID,
            conversationID: otherToolDelivery.conversationID,
            triggerRemoteMID: otherToolDelivery.triggerRemoteMID,
            attachmentSHA256: otherToolDelivery.attachmentSHA256
        )
        scopedState.resumeDeliveryRecords.append(otherToolDelivery)
        let scopedJob = JobListing(id: "boss-scoped-job", accountID: manualAccount.id, title: "Java", company: "公司 A")
        let otherScopedJob = JobListing(id: "boss-other-job", accountID: otherStatisticsAccount.id, title: "Python", company: "公司 B")
        scopedState.jobs = [scopedJob, otherScopedJob]
        var scopedConversation = cascadeConversation
        scopedConversation.accountID = manualAccount.id
        var otherScopedConversation = scopedConversation
        otherScopedConversation.id = "boss-other-conversation"
        otherScopedConversation.accountID = otherStatisticsAccount.id
        scopedState.conversations = [scopedConversation, otherScopedConversation]
        try scopedPersistence.save(scopedState)
        let scopedStore = AppStore(persistence: scopedPersistence)
        scopedStore.load()
        let otherDailyRecord = AutomaticGreetingSafetyRecord(
            remoteIdentityID: otherStatisticsProfile.remoteID, remoteJobID: "tool-role", attemptedAt: manualTime
        )
        scopedStore.recordDailyCommunications(parsedDaily.records + [otherDailyRecord], now: manualTime)
        try verify(
            scopedStore.communicationCountToday(accountID: manualAccount.id, now: manualTime) == 2 &&
            scopedStore.communicationCountToday(accountID: otherStatisticsAccount.id, now: manualTime) == 1 &&
            scopedStore.communicationCountToday(accountID: unboundStatisticsAccount.id, now: manualTime) == 0 &&
            scopedStore.communicationCountToday(accountID: UUID(), now: manualTime) == 0 &&
            scopedStore.communicationCountToday(now: manualTime) == 3,
            "沟通统计未按账号身份隔离，或未保留手动与工具去重"
        )
        try verify(
            scopedStore.resumeExchangeCountToday(accountID: manualAccount.id, now: manualTime) == 1 &&
            scopedStore.resumeExchangeCountToday(accountID: otherStatisticsAccount.id, now: manualTime) == 1,
            "未核对的工具交换统计串号"
        )
        scopedStore.recordDailyResumeExchanges(parsedDaily.records + [otherDailyRecord], now: manualTime)
        scopedStore.completeDailyResumeExchangeSync(remoteIdentityID: manualProfile.remoteID, startedAt: manualTime)
        try verify(
            scopedStore.resumeExchangeCountToday(accountID: manualAccount.id, now: manualTime) == 2 &&
            scopedStore.resumeExchangeCountToday(accountID: otherStatisticsAccount.id, now: manualTime) == 1 &&
            scopedStore.dailyResumeExchangeLastSyncedAt(accountID: otherStatisticsAccount.id, now: manualTime) == nil &&
            scopedStore.resumeExchangeCountToday(accountID: unboundStatisticsAccount.id, now: manualTime) == 0 &&
            scopedStore.resumeExchangeCountToday(accountID: UUID(), now: manualTime) == 0,
            "已核对账号的官方交换统计与未核对账号的工具记录混合"
        )
        scopedStore.completeDailyResumeExchangeSync(remoteIdentityID: otherStatisticsProfile.remoteID, startedAt: manualTime)
        try verifyRetainedAccountSignOut(snapshot: scopedStore.snapshot, accountID: manualAccount.id, now: manualTime)
        passed.append("account sign-out preserves local data and restores statistics on login")
        scopedStore.selectedAccountID = manualAccount.id
        scopedStore.selectedJobID = scopedJob.id
        scopedStore.selectedConversationID = scopedConversation.id
        scopedStore.createDraftAction(accountID: manualAccount.id, conversationID: nil, jobID: scopedJob.id, kind: .sendGreeting, content: "草稿", reason: "测试")
        scopedStore.createDraftAction(accountID: manualAccount.id, conversationID: scopedConversation.id, jobID: nil, kind: .sendMessage, content: "回复", reason: "测试")
        scopedStore.createDraftAction(accountID: otherStatisticsAccount.id, conversationID: otherScopedConversation.id, jobID: nil, kind: .sendMessage, content: "保留", reason: "测试")
        scopedStore.removeJob(id: scopedJob.id)
        scopedStore.removeConversation(id: scopedConversation.id)
        scopedStore.flush()
        let scopedReloaded = AppStore(persistence: scopedPersistence)
        scopedReloaded.load()
        try verify(
            scopedStore.selectedJobID == nil && scopedStore.selectedConversationID == nil &&
            scopedReloaded.snapshot.jobs.map(\.id) == [otherScopedJob.id] &&
            scopedReloaded.snapshot.conversations.map(\.id) == [otherScopedConversation.id] &&
            scopedReloaded.snapshot.pendingActions.count == 1 &&
            scopedReloaded.snapshot.pendingActions.first?.accountID == otherStatisticsAccount.id &&
            scopedReloaded.snapshot.automaticGreetingAttempts.count == 2 &&
            scopedReloaded.snapshot.resumeDeliveryRecords.count == 2 &&
            scopedReloaded.communicationCountToday(accountID: manualAccount.id, now: manualTime) == 2 &&
            scopedReloaded.resumeExchangeCountToday(accountID: manualAccount.id, now: manualTime) == 2 &&
            scopedReloaded.resumeExchangeCountToday(accountID: otherStatisticsAccount.id, now: manualTime) == 1 &&
            scopedReloaded.resumeExchangeCountToday(accountID: manualAccount.id, now: nextManualDay) == 0,
            "本地删除未持久化、影响其他账号，或清除了沟通与投递安全账本"
        )
        passed.append("account scoped communication and resume exchange statistics")
        passed.append("local deletion account isolation and durable safety ledgers")

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-SelfCheck-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let persistence = JSONStatePersistence(fileURL: stateURL)
        var state = AppSnapshot()
        let persistedAccount = BossAccount(displayName: "往返测试")
        state.accounts = [persistedAccount]
        let persistedSafetyCooldown = Date(timeIntervalSince1970: 1_700_086_400)
        state.automation.safetyCooldownUntil = persistedSafetyCooldown
        try persistence.save(state)
        let loaded = try persistence.load()
        let permissions = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
        try verify(
            loaded.accounts.first?.displayName == "往返测试" &&
                loaded.automation.safetyCooldownUntil == persistedSafetyCooldown,
            "状态或安全冷却往返失败"
        )
        try verify(permissions?.intValue == 0o600, "状态文件权限不是 0600")
        passed.append("state persistence")

        let debouncedStore = AppStore(persistence: persistence)
        debouncedStore.load()
        debouncedStore.addAccount(named: "first pending change")
        debouncedStore.addAccount(named: "latest pending change")
        let saveDeadline = Date().addingTimeInterval(1)
        var savedLatestChange = false
        while !savedLatestChange, Date() < saveDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            savedLatestChange = try persistence.load().accounts.last?.displayName == "latest pending change"
        }
        try verify(savedLatestChange, "合并保存未写入最新快照")
        let savedData = try Data(contentsOf: stateURL)
        try verify(!savedData.contains(0x0a), "状态文件仍包含多余的格式化换行")
        passed.append("debounced latest snapshot and compact persistence")

        let terminationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-TerminationFlush-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: terminationURL.deletingLastPathComponent()) }
        let terminationPersistence = JSONStatePersistence(fileURL: terminationURL)
        let terminationStore = AppStore(persistence: terminationPersistence)
        let terminationAccountID = terminationStore.addBossAccount()
        let terminationController = BossAutomationController()
        var terminationCompleted = false
        Task { @MainActor in
            await terminationController.prepareForTermination(
                using: terminationStore,
                gracefulTimeoutNanoseconds: 0
            )
            terminationCompleted = true
        }
        let terminationDeadline = Date().addingTimeInterval(2)
        while !terminationCompleted, Date() < terminationDeadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        let terminationSnapshot = try terminationPersistence.load()
        try verify(
            terminationCompleted &&
            terminationSnapshot.accounts.contains { $0.id == terminationAccountID },
            "空闲自动化 Controller 退出时未完成优雅收敛或未 flush 最新 AppStore"
        )
        passed.append("idle automation termination flush")

        let legacyBackupURL = stateURL.deletingLastPathComponent().appendingPathComponent("state.backup.json")
        try Data("legacy-sensitive-state".utf8).write(to: legacyBackupURL)
        _ = try persistence.load()
        try verify(!FileManager.default.fileExists(atPath: legacyBackupURL.path), "旧版敏感状态备份未清理")
        passed.append("legacy backup cleanup")

        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-Corrupt-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: corruptURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: corruptURL)
        let corruptStore = AppStore(persistence: JSONStatePersistence(fileURL: corruptURL))
        corruptStore.load()
        try verify(corruptStore.persistenceBlocked, "损坏状态未禁止后续写入")
        corruptStore.addAccount(named: "不应写入")
        corruptStore.flush()
        let preservedCorruptData = try Data(contentsOf: corruptURL)
        try verify(preservedCorruptData == corruptData, "损坏状态被空数据覆盖")
        passed.append("corrupt state fail closed")

        return passed
    }

    private static func verifyBackgroundPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-BackgroundSave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
        var older = AppSnapshot()
        older.resume.text = String(repeating: "fixture ", count: 2_000_000)
        let blockingStartedAt = Date()
        try persistence.save(older)
        let blockingDuration = Date().timeIntervalSince(blockingStartedAt)
        let startedAt = Date()
        persistence.saveInBackground(older) { _ in }
        let enqueueDuration = Date().timeIntervalSince(startedAt)
        var durable = AppSnapshot()
        durable.automaticGreetingAttempts = [AutomaticGreetingAttempt(
            accountID: UUID(), remoteIdentityID: "fixture-owner", remoteJobID: "fixture-job",
            deliveryWriteStartedAt: Date()
        )]
        try persistence.save(durable)
        let restored = try persistence.load()
        try verify(restored.automaticGreetingAttempts.count == 1 && restored.resume.text.isEmpty,
                   "旧后台保存覆盖了外发持久化记录")
        let symlink = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: persistence.fileURL)
        let rejected = JSONStatePersistence(fileURL: symlink)
        let finished = DispatchSemaphore(value: 0)
        rejected.saveInBackground(older) { result in
            if case .failure = result { finished.signal() }
        }
        try verify(finished.wait(timeout: .now() + 5) == .success, "后台保存忽略符号链接保护或吞掉错误")
        print(String(format: "PERF 16 MB state: blocking %.2f ms, main-thread enqueue %.2f ms; durable save follows older background save",
                     blockingDuration * 1000, enqueueDuration * 1000))
    }

    private static func verifyResumeJavaScriptLifecycle() throws {
        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            do {
                try await BossResumeExchangeProtocolSelfCheck.verifyJavaScriptLifecycle()
                completion = .success(())
            } catch { completion = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(30)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let completion else { task.cancel(); throw SelfCheckError.failed("简历 JavaScript 生命周期测试超时") }
        try completion.get()
    }

    private static func verifyBatchOperationsAndListCaches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-Bulk-\(UUID())/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persistence = JSONStatePersistence(fileURL: url)
        var state = AppSnapshot()
        var first = BossAccount(displayName: "A")
        var profile = BossAccountProfile(); profile.remoteID = "bulk-a"; first.remoteProfile = profile
        var second = BossAccount(displayName: "B")
        profile.remoteID = "bulk-b"; second.remoteProfile = profile
        state.accounts = [first, second]
        state.jobs = (0..<1200).map { JobListing(id: "boss-bulk-job-\($0)", accountID: $0 % 2 == 0 ? first.id : second.id, title: "Java", company: "测试") }
        state.conversations = (0..<400).map {
            Conversation(id: "boss-bulk-chat-\($0)", accountID: $0 % 2 == 0 ? first.id : second.id,
                         recruiterName: "招聘方", company: "测试", jobTitle: "Java", messages: [], unreadCount: 1,
                         lastSyncedAt: Date(), sourceURL: "")
        }
        state.pendingActions = state.conversations.map {
            PendingAction(accountID: $0.accountID, conversationID: $0.id, kind: .sendMessage, content: "草稿", reason: "测试")
        }
        state.automaticGreetingAttempts = [AutomaticGreetingAttempt(accountID: first.id, remoteIdentityID: "bulk-a", remoteJobID: "history")]
        try persistence.save(state)
        let store = AppStore(persistence: persistence); store.load()
        let cold = Date()
        let originalRows = store.conversationDisplayRows
        _ = store.jobsInDisplayOrder
        let coldDuration = Date().timeIntervalSince(cold)
        let warm = Date()
        for _ in 0..<200 {
            try verify(store.conversationDisplayRows.count == 400 && store.jobsInDisplayOrder.count == 1200, "列表缓存丢失数据")
        }
        let warmDuration = Date().timeIntervalSince(warm)
        try verify(warmDuration < max(0.03, coldDuration * 5), "重复读取列表仍在全量分类排序")
        var publications = 0
        let subscription = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let chats = Set(state.conversations.filter { $0.accountID == first.id }.map(\.id))
        store.markConversationsHandled(ids: chats)
        try verify(publications == 1 && originalRows.allSatisfy { $0.state == .pending } &&
                   store.conversationDisplayRows.filter { chats.contains($0.conversation.id) }.allSatisfy { $0.state == .processed },
                   "批量标记未一次发布或缓存未失效")
        publications = 0
        store.removeConversations(ids: chats)
        try verify(publications == 1 && store.conversationDisplayRows.count == 200 &&
                   store.snapshot.pendingActions.count == 200 && store.snapshot.conversations.allSatisfy { $0.accountID == second.id },
                   "批量删除会话未一次发布或误删其他账号")
        publications = 0
        let jobs = Set(state.jobs.filter { $0.accountID == first.id }.map(\.id))
        store.removeJobs(ids: jobs)
        try verify(publications == 1 && store.jobsInDisplayOrder.count == 600 &&
                   store.snapshot.automaticGreetingAttempts.count == 1 && store.snapshot.automaticGreetingSafetyRecords.count == 1,
                   "批量删除岗位未一次发布或破坏安全账本")
        store.flush()
        let reloaded = try persistence.load()
        try verify(reloaded.jobs.count == 600 && reloaded.conversations.count == 200, "批量结果未持久化")
        print(String(format: "PERF list cache: cold %.2f ms; 200 warm reads %.2f ms; batch mutations one publication each", coldDuration * 1000, warmDuration * 1000))
    }

    private static func verifyBackgroundResponsiveness() throws {
        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-Background-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let store = AppStore(persistence: JSONStatePersistence(fileURL: root.appendingPathComponent("state.json")))
                let accountID = store.addBossAccount()
                store.updateResume { $0.text = "6年 Java Python 后端研发，熟悉 Spring MySQL Docker"; $0.skills = ["Java", "Python"] }
                store.updatePreferences { $0.requirementText = "上海 Java 后端，排除外包" }
                let jobs = (0..<1200).map { index in
                    var job = JobListing(id: "boss-background-\(index)", accountID: accountID,
                        title: "Java 后端研发工程师", company: "测试公司", location: "上海", salary: "35-45K",
                        experience: "3-5年", education: "本科", description: "使用 Java Spring MySQL 开发业务系统，负责架构设计与 Docker 部署。")
                    job.detailFetchedAt = Date()
                    return job
                }
                store.upsertJobs(jobs)
                var ticks: [Date] = []
                let heartbeat = Task { @MainActor in
                    while !Task.isCancelled {
                        ticks.append(Date())
                        do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    }
                }
                defer { heartbeat.cancel() }
                var publications = 0
                let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
                defer { observation.cancel() }
                let start = Date()
                let assessed = await store.assessPendingJobsLocally(accountID: accountID)
                let end = Date()
                let measurements = [start] + ticks + [end]
                let largestGap = zip(measurements, measurements.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
                try verify(assessed == 1200 && publications == 1 && largestGap < 0.25 &&
                           (end.timeIntervalSince(start) < 0.03 || ticks.count > 2),
                           "后台评估阻塞主线程或逐条发布：数量 \(assessed)，发布 \(publications)，心跳 \(ticks.count)，最大间隔 \(largestGap)")
                print(String(format: "RESPONSIVENESS 1200 assessments: %.0f ms total, main actor heartbeat gap %.1f ms, one publication",
                             end.timeIntervalSince(start) * 1000, largestGap * 1000))

                store.updatePreferences { $0.requirementText = "杭州 Python 后端" }
                let stale = Task { await store.assessPendingJobsLocally(accountID: accountID) }
                try await Task.sleep(for: .milliseconds(10))
                store.updatePreferences { $0.requirementText = "只考虑南京 Java，不接受外包" }
                _ = await stale.value
                try verify(store.snapshot.jobs.allSatisfy { $0.assessment == nil }, "旧要求的后台评估覆盖了新要求")
                publications = 0
                let cancelled = Task { await store.assessPendingJobsLocally(accountID: accountID) }
                try await Task.sleep(for: .milliseconds(10))
                cancelled.cancel()
                let cancelledCount = await cancelled.value
                try verify(cancelledCount == 0 && publications == 0, "已取消的后台评估仍提交结果")
                let deleting = Task { await store.assessPendingJobsLocally(accountID: accountID) }
                try await Task.sleep(for: .milliseconds(10))
                store.removeJobs(ids: Set(jobs.map(\.id)))
                _ = await deleting.value
                try verify(store.snapshot.jobs.isEmpty, "后台评估恢复了已删除的岗位")

                let input = root.appendingPathComponent("large.txt")
                try Data(String(repeating: "6年 Java Python 业务系统研发与交付经验。\n", count: 50_000).utf8).write(to: input)
                ticks = []
                let importStart = Date()
                let imported = try await ResumeImportService.shared.importFile(from: input,
                    storageDirectory: root.appendingPathComponent("Attachments"))
                let importEnd = Date()
                let importMeasurements = [importStart] + ticks + [importEnd]
                let importGap = zip(importMeasurements, importMeasurements.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
                try verify(imported.text.count > 1_000_000 && imported.inferredYearsOfExperience == 6 &&
                           imported.attachmentPath?.hasPrefix(root.path) == true && importGap < 0.25 &&
                           (importEnd.timeIntervalSince(importStart) < 0.03 || ticks.count > 2),
                           "简历文件提取阻塞主线程或写入了隔离目录之外")
                print(String(format: "RESPONSIVENESS large resume import: %.0f ms total, main actor heartbeat gap %.1f ms",
                             importEnd.timeIntervalSince(importStart) * 1000, importGap * 1000))
                completion = .success(())
            } catch { completion = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(40)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard let completion else { task.cancel(); throw SelfCheckError.failed("后台响应测试超时") }
        try completion.get()
    }

    private static func completePendingAssessments(_ store: AppStore, accountID: UUID) throws -> Int {
        var result: Int?
        let task = Task { result = await store.assessPendingJobsLocally(accountID: accountID) }
        let deadline = Date().addingTimeInterval(30)
        while result == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard let result else { task.cancel(); throw SelfCheckError.failed("后台岗位评估超时") }
        return result
    }

    private static func verifyResumeUpdateBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-ResumeBatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attachment = root.appendingPathComponent("resume.txt")
        try Data("Java backend engineer".utf8).write(to: attachment)
        let store = AppStore(persistence: JSONStatePersistence(fileURL: root.appendingPathComponent("state.json")))
        let accountID = store.addBossAccount()
        store.updateResume { $0.attachmentPath = attachment.path; $0.text = "Java 后端研发"; $0.profileSummary = "原画像" }
        store.updatePreferences { $0.requirementText = "上海 Java" }
        let jobs = (0..<6000).map { index in
            var job = JobListing(id: "profile-batch-\(index)", accountID: accountID, title: "Java", company: "测试公司")
            job.stage = JobStage.allCases[index % JobStage.allCases.count]
            job.assessment = JobAssessment(score: 90, recommendation: "推荐", confidence: .high,
                reasons: [], risks: [], greeting: "", assessedAt: Date(), provider: "测试")
            return job
        }
        store.upsertJobs(jobs)
        let originalStages = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.stage) })
        store.createDraftAction(accountID: accountID, conversationID: nil, jobID: jobs[0].id,
                                kind: .sendGreeting, content: "旧开聊", reason: "旧条件")
        store.createDraftAction(accountID: accountID, conversationID: nil, jobID: jobs[1].id,
                                kind: .sendMessage, content: "保留回复", reason: "已有沟通")
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let start = Date()
        store.applyResumeIntelligence(ResumeIntelligence(profileSummary: "新的后端工程师画像", searchQueries: ["Java"],
            cities: [], provider: "测试"), expectedResumeID: store.snapshot.resume.id)
        let duration = Date().timeIntervalSince(start)
        try verify(publications == 1 && duration < 2 && store.snapshot.jobs.count == 6000 &&
                   store.snapshot.jobs.allSatisfy { $0.assessment == nil } &&
                   store.snapshot.jobs.allSatisfy { job in
                       guard let original = originalStages[job.id] else { return false }
                       return job.stage == ([JobStage.discovered, .rejected, .recommended].contains(original) ? .discovered : original)
                   } && store.snapshot.pendingActions.count == 1 && store.snapshot.pendingActions[0].kind == .sendMessage,
                   "画像批量更新失败：发布 \(publications)，耗时 \(duration)，岗位 \(store.snapshot.jobs.count)，前八项 \(store.snapshot.jobs.prefix(8).map(\.stage))，待办 \(store.snapshot.pendingActions.map(\.kind))")
        publications = 0
        store.applySearchPlan(JobSearchPlan(queries: ["Java"], cities: ["上海"], provider: "测试"),
                              requirementText: store.snapshot.preferences.requirementText, resumeID: store.snapshot.resume.id)
        try verify(publications == 1 && store.snapshot.preferences.plannedSearchQueries == ["Java"], "检索计划更新未合并发布")
        publications = 0
        store.updatePreferences { $0.requirementText = "杭州 Python" }
        try verify(publications == 1 && store.snapshot.preferences.plannedSearchQueries.isEmpty, "要求更新未合并发布或沿用旧计划")
        publications = 0
        store.updateResume { $0.skills = ["Python"] }
        try verify(publications == 1, "简历编辑未合并发布")
        publications = 0
        store.updatePreferences { _ in }
        store.updateResume { _ in }
        try verify(publications == 0, "未变化的编辑仍刷新所有界面")
        print(String(format: "PERF 6000-job profile update: %.1f ms; one publication; prior chat stages preserved", duration * 1000))
    }

    private static func verifyManualRequirementsSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-Drafts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            do {
                let url = root.appendingPathComponent("state.json")
                let persistence = JSONStatePersistence(fileURL: url)
                var fixture = AppSnapshot()
                fixture.preferences.requirementText = "上海 Java 社招"
                fixture.preferences.greetingTemplate = "原草稿"
                try persistence.save(fixture)
                let store = AppStore(persistence: persistence)
                store.load()
                store.beginRequirementsEditing()
                store.requirementsDraft?.requirementText = "杭州 Python，不考虑校招"
                store.requirementsDraft?.greetingTemplate = "新草稿"
                store.flush()
                let beforeSave = try persistence.load()
                try verify(store.hasUnsavedRequirementsChanges && store.isEditingRequirements &&
                           store.snapshot.preferences.requirementText == fixture.preferences.requirementText &&
                           beforeSave.preferences.greetingTemplate == "原草稿",
                           "未点击保存时，文本已应用或被其他状态写入顺带保存")
                store.finishRequirementsEditing()
                try verify(store.requirementsDraft?.greetingTemplate == "新草稿", "未保存的草稿被离开页面静默丢弃")
                store.discardRequirementsChanges()
                try verify(!store.hasUnsavedRequirementsChanges && !store.isEditingRequirements &&
                           store.requirementsDraft?.requirementText == fixture.preferences.requirementText,
                           "放弃修改未还原已保存内容")
                store.requirementsDraft?.requirementText = "杭州 Python，不考虑校招"
                store.requirementsDraft?.greetingTemplate = "新草稿"
                let saved = await store.saveRequirementsChanges()
                let persisted = try persistence.load()
                try verify(saved && !store.hasUnsavedRequirementsChanges && store.requirementsDraft != nil &&
                           persisted.preferences.requirementText == "杭州 Python，不考虑校招" &&
                           persisted.preferences.greetingTemplate == "新草稿",
                           "显式保存未落盘、提前清空编辑器，或未更新保存基线")
                store.requirementsDraft?.greetingTemplate = "继续编辑"
                store.discardRequirementsChanges()
                try verify(store.requirementsDraft?.greetingTemplate == "新草稿", "保存后放弃修改回到了过期草稿")
                store.requirementsDraft?.greetingTemplate = "写入失败时保留"
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                let failedSave = await store.saveRequirementsChanges()
                store.finishRequirementsEditing()
                try verify(!failedSave && store.hasUnsavedRequirementsChanges && !store.isSavingRequirements &&
                           store.requirementsDraft?.greetingTemplate == "写入失败时保留" && store.lastError != nil,
                           "保存失败后被误报成功或丢失了未保存内容")
                store.discardRequirementsChanges()
                try verify(store.snapshot.preferences.greetingTemplate == "新草稿", "保存失败后放弃修改未恢复原配置")
                store.finishRequirementsEditing()
                try verify(store.requirementsDraft == nil && !store.isEditingRequirements,
                           "确认离开后编辑状态未释放")
                completion = .success(())
            } catch { completion = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let completion else {
            task.cancel()
            throw SelfCheckError.failed("要求手动保存测试超时")
        }
        try completion.get()
    }

    private static func verifyCampusRecruitmentExclusions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BossPilot-CampusExclusions-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var state = AppSnapshot()
        state.preferences.requirementText = ""
        var account = BossAccount(displayName: "排除条件测试")
        var profile = BossAccountProfile()
        profile.remoteID = "campus-exclusion-fixture"
        account.remoteProfile = profile
        state.accounts = [account]
        var cohort = JobListing(id: "cohort", accountID: account.id,
                                title: "应用开发工程师-27届可转正-提供餐补", company: "示例公司")
        cohort.description = "AI 应用开发，负责产品研发。"
        cohort.detailFetchedAt = Date()
        cohort.remoteJobID = "cohort-remote"
        cohort.stage = .recommended
        var campus = cohort
        campus.id = "campus"
        campus.remoteJobID = "campus-remote"
        campus.title = "AI 应用开发工程师"
        campus.experience = "在校/应届"
        campus.securityID = "job-route"
        var social = campus
        social.id = "social"
        social.remoteJobID = "social-remote"
        social.company = "社招公司"
        social.experience = "3-5年"
        state.jobs = [cohort, campus, social]
        state.conversations = [campus, social].map { job in
            var conversation = Conversation(id: job.id, accountID: account.id, recruiterName: "招聘方",
                                            company: job.company, jobTitle: job.title, messages: [], unreadCount: 0,
                                            lastSyncedAt: Date(), sourceURL: "")
            conversation.securityID = "chat-route-\(job.id)"
            conversation.remoteConversationID = "remote-\(job.id)"
            return conversation
        }
        var unknown = state.conversations[0]
        unknown.id = "unknown"
        unknown.remoteConversationID = "remote-unknown"
        unknown.company = "未同步岗位的公司"
        state.conversations.append(unknown)
        let persistence = JSONStatePersistence(fileURL: url)
        try persistence.save(state)
        let store = AppStore(persistence: persistence)
        store.load()
        try verify(store.snapshot.conversations.count == 3, "校招回归会话未加载")
        try store.prepareAutomaticGreeting(jobID: cohort.id)
        let requirements = "我是社招的，不考虑校招、实习类岗位，这条是严格遵循。"
        store.updatePreferences { $0.requirementText = requirements }
        var blocked = false
        do { try store.markAutomaticGreetingWriteStarted(jobID: cohort.id) }
        catch BossAutomationError.operationNotReady { blocked = true }
        try verify(blocked && store.snapshot.automaticGreetingAttempts.first?.deliveryWriteStartedAt == nil,
                   "新增校招排除条件后，已有开聊预留仍可写入")
        store.setJobStage(id: campus.id, stage: .recommended)
        blocked = false
        do { try store.prepareAutomaticGreeting(jobID: campus.id) }
        catch BossAutomationError.operationNotReady { blocked = true }
        try verify(blocked, "标题未写校招的在校/应届岗位仍可预留开聊")
        let optimisticAssessment = JobAssessment(score: 100, recommendation: "推荐", confidence: .high,
                                                reasons: [], risks: [], greeting: "你好", assessedAt: Date(), provider: "Codex")
        store.applyCodexAssessment(optimisticAssessment, to: campus.id)
        try verify(store.snapshot.jobs.first(where: { $0.id == campus.id })?.stage == .rejected,
                   "Codex 评估覆盖了校招硬性排除条件")
        try verify(!store.allowsAutomaticResumeDelivery(accountID: account.id, conversationID: campus.id),
                   "会话与岗位 securityID 不同，导致应届经验漏过附件投递检查")
        try verify(!store.allowsAutomaticResumeDelivery(accountID: account.id, conversationID: unknown.id),
                   "没有岗位证据时仍绕过校招排除条件发送附件")
        try verify(store.allowsAutomaticResumeDelivery(accountID: account.id, conversationID: social.id),
                   "正常社招岗位被附件投递检查误拒")
        for (field, value) in [("experience", "在校生"), ("tags", "2027届"), ("description", "面向2027届毕业生招聘")] {
            var job = social
            if field == "experience" { job.experience = value }
            if field == "tags" { job.tags = [value] }
            if field == "description" { job.description = value }
            let assessment = JobMatchingPolicy.assess(job: job, resume: state.resume, preferences: store.snapshot.preferences)
            try verify(assessment.score == 0 && !JobMatchingPolicy.hardGateFailures(job: job, preferences: store.snapshot.preferences).isEmpty,
                       "校招证据未在评估和发送前拦截：\(field)")
        }
        for title in ["全栈开发工程师（Ai agent）(不是27校招岗)", "社招研发（非应届）", "Internal AI tools engineer"] {
            var job = social
            job.title = title
            try verify(JobMatchingPolicy.matchingExclusions(in: job.evidenceText, preferences: store.snapshot.preferences).isEmpty,
                       "正常社招标题被校招或实习关键词误拒：\(title)")
        }
        var aliases = store.snapshot.preferences
        aliases.requirementText = "不考虑校园招聘、实习生岗位。"
        try verify(!JobMatchingPolicy.matchingExclusions(in: cohort.evidenceText, preferences: aliases).isEmpty &&
                   !JobMatchingPolicy.matchingExclusions(in: "AI intern", preferences: aliases).isEmpty,
                   "排除条件使用同义词时漏判")
    }

    private static func verifyRetainedAccountSignOut(snapshot: AppSnapshot, accountID: UUID, now: Date) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-SignOut-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
        try persistence.save(snapshot)
        let store = AppStore(persistence: persistence)
        store.load()
        let before = store.snapshot
        let account = try required(before.accounts.first { $0.id == accountID }, "退出测试账号缺失")
        let other = try required(store.statisticsAccounts.first { $0.id != accountID }, "退出测试缺少其他账号")
        let greetings = store.communicationCountToday(now: now)
        let exchanges = store.resumeExchangeCountToday(now: now)
        let confirmed = store.confirmedAutomaticGreetingCountToday(now: now)
        let quota = store.automaticGreetingCountToday(accountID: accountID, now: now)
        let otherGreetings = store.communicationCountToday(accountID: other.id, now: now)
        let otherExchanges = store.resumeExchangeCountToday(accountID: other.id, now: now)
        let otherConfirmed = store.confirmedAutomaticGreetingCountToday(accountID: other.id, now: now)
        store.accountFilterIDs = [accountID]
        try verify(store.statisticsAccounts.map(\.id) == [accountID] &&
                   store.totalDailyGreetingLimit() == snapshot.automation.dailyGreetingLimit,
                   "统计未遵循全局账号选择")
        store.accountFilterIDs = nil
        try store.beginBossSignOut(accountID: accountID)
        var expected = before
        expected.accounts[try required(expected.accounts.firstIndex { $0.id == accountID }, "退出账号索引缺失")].loginStatus = .loggedOut
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedData = try encoder.encode(expected)
        let signedOutData = try encoder.encode(store.snapshot)
        try verify(signedOutData == expectedData, "退出改动了登录标记之外的本地数据")
        try verify(store.statisticsAccounts.map(\.id) == [other.id] && store.includesAccount(accountID) &&
                   store.communicationCountToday(now: now) == otherGreetings &&
                   store.resumeExchangeCountToday(now: now) == otherExchanges &&
                   store.confirmedAutomaticGreetingCountToday(now: now) == otherConfirmed &&
                   store.totalDailyGreetingLimit() == snapshot.automation.dailyGreetingLimit &&
                   store.automaticGreetingCountToday(accountID: accountID, now: now) == quota,
                   "退出后仍计入汇总，或清空了历史额度/本地浏览范围")
        let reloaded = AppStore(persistence: persistence)
        reloaded.load()
        let reloadedData = try encoder.encode(reloaded.snapshot)
        try verify(reloadedData == expectedData, "退出未持久化或重启后丢失本地数据")
        reloaded.accountFilterIDs = [accountID]
        try verify(reloaded.statisticsAccounts.isEmpty && reloaded.totalDailyGreetingLimit() == 0 &&
                   reloaded.communicationCountToday(now: now) == 0 && reloaded.resumeExchangeCountToday(now: now) == 0,
                   "单独选择已退出账号时仍产生汇总统计")
        reloaded.accountFilterIDs = nil
        _ = try reloaded.applyBossProfile(try required(account.remoteProfile, "退出测试缺少身份"), accountID: accountID)
        reloaded.synchronizeBossLoginStatus(accountID: accountID, loggedIn: true)
        reloaded.flush()
        let loggedIn = AppStore(persistence: persistence)
        loggedIn.load()
        try verify(loggedIn.statisticsAccounts.count == 2 && loggedIn.communicationCountToday(now: now) == greetings &&
                   loggedIn.resumeExchangeCountToday(now: now) == exchanges &&
                   loggedIn.confirmedAutomaticGreetingCountToday(now: now) == confirmed &&
                   loggedIn.snapshot.jobs == before.jobs && loggedIn.snapshot.conversations == before.conversations &&
                   loggedIn.snapshot.resumeDeliveryRecords == before.resumeDeliveryRecords &&
                   loggedIn.snapshot.automaticGreetingSafetyRecords == before.automaticGreetingSafetyRecords &&
                   loggedIn.automaticGreetingCountToday(accountID: accountID, now: now) == quota &&
                   loggedIn.snapshot.accounts.first { $0.id == accountID }?.webProfileID == account.webProfileID,
                   "重新登录没有恢复统计，或更换了账号绑定/丢失历史")

        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            do {
                let vault = BossCredentialVault(directoryURL: root.appendingPathComponent("Sessions"))
                let cookies = try ["wt2", "zp_at"].map { name in
                    try required(HTTPCookie(properties: [.name: name, .value: "isolated-signout-fixture",
                        .domain: ".zhipin.com", .path: "/"]), "无法创建隔离 Cookie")
                }
                try vault.save(BossCredential(cookies: cookies), profileID: account.webProfileID)
                try vault.save(BossCredential(cookies: cookies), profileID: other.webProfileID)
                await BossWebSessionService.importCookies(cookies, profileID: account.webProfileID)
                await BossWebSessionService.importCookies(cookies, profileID: other.webProfileID)
                let session = BossAccountSessionController(accountID: accountID, profileID: account.webProfileID,
                    allowsCredentialRestore: true, credentialVault: vault)
                session.beginSignOutBarrier()
                try await session.signOut()
                session.qrLogin.stop()
                let remaining = await BossWebSessionService.cookies(profileID: account.webProfileID)
                let untouched = await BossWebSessionService.cookies(profileID: other.webProfileID)
                let removedCredential = try vault.load(profileID: account.webProfileID)
                let retainedCredential = try vault.load(profileID: other.webProfileID)
                try verify(session.phase == .loginRequired && remaining.isEmpty && removedCredential == nil &&
                           retainedCredential?.hasIdentity == true && !untouched.isEmpty,
                           "退出没有清理目标登录会话或影响了其他账号")
                for profileID in [account.webProfileID, other.webProfileID] {
                    try await BossWebSessionService.clear(dataStore: BossWebSessionService.dataStore(for: profileID))
                    BossWebSessionService.releaseCachedStore(for: profileID)
                    try await BossWebSessionService.removePersistentStore(for: profileID)
                }
                completion = .success(())
            } catch { completion = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(20)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let completion else { task.cancel(); throw SelfCheckError.failed("隔离账号退出超时") }
        try completion.get()
    }

    private static func verifyGlobalAccountFilter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-AccountFilter-\(UUID())/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppStore(persistence: JSONStatePersistence(fileURL: url))
        store.load()
        let first = store.addBossAccount()
        let second = store.addBossAccount()
        try verify(store.filteredAccounts.count == 2 && store.includesAccount(first) && store.includesAccount(second), "默认未全选账号")
        store.toggleAccountFilter(first)
        store.selectedAccountID = first
        try verify(store.filteredAccounts.map(\.id) == [second] && !store.includesAccount(first), "账号详情焦点改变了全局筛选")
        store.toggleAccountFilter(second)
        try verify(store.filteredAccounts.isEmpty && !store.includesAccount(second), "空选择被当成全选")
        store.accountFilterIDs = nil
        let third = store.addBossAccount()
        try verify(store.filteredAccounts.count == 3 && store.includesAccount(third), "全选未包含新账号")
        store.accountFilterIDs = [first, third]
        try store.beginAccountDeletion(id: third)
        try verify(store.filteredAccounts.map(\.id) == [first] && !store.includesAccount(third), "筛选仍包含正在删除的账号")
    }

    private static func verifyAccountRenaming() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-AccountRename-\(UUID())/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persistence = JSONStatePersistence(fileURL: url)
        let store = AppStore(persistence: persistence)
        store.load()
        let firstID = store.addBossAccount()
        let secondID = store.addBossAccount()
        var profile = BossAccountProfile()
        profile.remoteID = "rename-identity"
        profile.name = "BOSS 姓名"
        _ = try store.applyBossProfile(profile, accountID: firstID)
        let original = try required(store.snapshot.accounts.first { $0.id == firstID }, "重命名测试账号缺失")
        store.renameAccount(id: firstID, name: "  工作账号  ")
        store.renameAccount(id: firstID, name: " \n\t ")
        store.renameAccount(id: UUID(), name: "不存在的账号")
        profile.name = "刷新后的 BOSS 姓名"
        _ = try store.applyBossProfile(profile, accountID: firstID)
        store.flush()
        let reloaded = AppStore(persistence: persistence)
        reloaded.load()
        let renamed = try required(reloaded.snapshot.accounts.first { $0.id == firstID }, "重命名未持久化")
        try verify(
            renamed.customName == "工作账号" && renamed.selectionLabel(in: reloaded.snapshot.accounts) == "工作账号" &&
            original.selectionLabel(in: reloaded.snapshot.accounts) == "工作账号" &&
            renamed.remoteProfile?.name == profile.name && renamed.displayName == profile.name &&
            renamed.id == original.id && renamed.webProfileID == original.webProfileID &&
            reloaded.snapshot.accounts.first { $0.id == secondID }?.customName == nil,
            "自定义名称未去除空白、被资料刷新覆盖，或影响账号身份与其他账号"
        )
        reloaded.renameAccount(id: secondID, name: "工作账号")
        let labels = reloaded.snapshot.accounts.map { $0.selectionLabel(in: reloaded.snapshot.accounts) }
        try verify(Set(labels).count == 2 && labels.allSatisfy { $0.hasPrefix("工作账号 · 账号 ") },
                   "重命名后同名账号无法区分")
    }

    private static func verifyFriendSummaryBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-SummaryBatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
        let store = AppStore(persistence: persistence)
        let accountID = store.addBossAccount()
        let otherAccountID = store.addBossAccount()
        for (index, id) in [accountID, otherAccountID].enumerated() {
            var profile = BossAccountProfile()
            profile.remoteID = "summary-owner-\(index)"
            _ = try store.applyBossProfile(profile, accountID: id)
        }
        let summaries = (0..<1000).map { index in
            BossFriendSummary(conversationID: "summary-\(index)", recruiterName: "招聘方 \(index)", company: "测试公司",
                jobTitle: "Java 工程师", latestText: "你好", unreadCount: 1,
                updatedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                securityID: "route-\(index)", listID: "list", latestIsIncoming: true,
                encryptedBossID: "boss-\(index)", friendSource: "0", latestRemoteMID: "100", jobSalary: "30-40K", jobLocation: "上海")
        }
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let insertStartedAt = Date()
        let inserted = store.upsertBossFriendSummaries(summaries, accountID: accountID)
        let insertDuration = Date().timeIntervalSince(insertStartedAt)
        let insertPublications = publications
        publications = 0
        let refreshed = summaries.map { summary in
            var item = summary
            item.company = "更新公司"
            item.latestRemoteMID = "101"
            item.updatedAt = summary.updatedAt.addingTimeInterval(10)
            return item
        }
        let updateStartedAt = Date()
        let updated = store.upsertBossFriendSummaries(refreshed, accountID: accountID)
        let updateDuration = Date().timeIntervalSince(updateStartedAt)
        let updatePublications = publications
        print(String(format: "PERF 1000 friend summaries: insert %.1f ms (%d publications), update %.1f ms (%d publications)",
                     insertDuration * 1000, insertPublications, updateDuration * 1000, updatePublications))
        try verify(inserted == 1000 && updated == 1000 && store.snapshot.conversations.count == 1000 &&
                   store.snapshot.conversations.allSatisfy { $0.messages.count == 2 && $0.company == "更新公司" },
                   "会话摘要批量合并丢失消息或元数据")
        try verify(insertPublications == 1 && updatePublications == 1, "会话摘要逐字段发布完整状态")
        let repeated = store.upsertBossFriendSummaries(refreshed, accountID: accountID)
        try verify(repeated == 0 && store.snapshot.conversations.allSatisfy { $0.messages.count == 2 }, "重复摘要产生重复消息")
        _ = store.upsertBossFriendSummaries(summaries, accountID: accountID)
        try verify(store.snapshot.conversations.allSatisfy { $0.company == "更新公司" }, "旧摘要覆盖较新元数据")
        publications = 0
        _ = store.upsertBossFriendSummaries([], accountID: accountID)
        try verify(publications == 0, "空摘要触发状态刷新")
        _ = store.upsertBossFriendSummaries([summaries[0]], accountID: otherAccountID)
        try verify(store.snapshot.conversations.count == 1001 &&
                   store.snapshot.conversations.filter { $0.accountID == otherAccountID }.count == 1,
                   "相同远端会话 ID 跨账号合并")
        let scheduler = BossAutomationController(api: BossAPIService(allowsWebFallback: false))
        let firstRoutes = scheduler.historyRoutesForSynchronization(accountID: accountID, store: store, limit: 3)
        let nextRoutes = scheduler.historyRoutesForSynchronization(accountID: accountID, store: store, limit: 3)
        let newestID = store.snapshot.conversations.first { $0.accountID == accountID && $0.remoteConversationID == "summary-999" }?.id
        try verify(firstRoutes.count == 3 && firstRoutes.first?.conversationID == newestID &&
            nextRoutes.first?.conversationID == newestID &&
            Set(firstRoutes.dropFirst().map(\.conversationID)).isDisjoint(with: nextRoutes.dropFirst().map(\.conversationID)),
            "自动消息小批量同步遗漏最新来信或阻塞历史轮转")
        try verify(scheduler.historyRoutesForSynchronization(accountID: otherAccountID, store: store, limit: 3).count == 1,
            "消息优先同步跨账号串线")
        store.flush()
        let restored = try persistence.load()
        try verify(restored.conversations.count == 1001, "批量摘要未完整持久化")
        let scopedID = try required(store.snapshot.conversations.first {
            $0.accountID == accountID && $0.remoteConversationID == summaries[0].conversationID
        }?.id, "缺少旧会话 ID 迁移测试数据")
        store.createDraftAction(accountID: accountID, conversationID: scopedID, jobID: nil,
                                kind: .sendMessage, content: "隔离草稿", reason: "迁移测试")
        var legacy = store.snapshot
        let legacyIndex = try required(legacy.conversations.firstIndex { $0.id == scopedID }, "缺少旧会话")
        legacy.conversations[legacyIndex].id = summaries[0].conversationID
        for index in legacy.pendingActions.indices where legacy.pendingActions[index].conversationID == scopedID {
            legacy.pendingActions[index].conversationID = summaries[0].conversationID
        }
        let legacyPersistence = JSONStatePersistence(fileURL: root.appendingPathComponent("legacy.json"))
        try legacyPersistence.save(legacy)
        let legacyStore = AppStore(persistence: legacyPersistence)
        legacyStore.load()
        legacyStore.selectedConversationID = summaries[0].conversationID
        _ = legacyStore.upsertBossFriendSummaries([refreshed[0], refreshed[0]], accountID: accountID)
        try verify(legacyStore.snapshot.conversations.count == 1001 &&
                   legacyStore.selectedConversationID == scopedID &&
                   legacyStore.snapshot.pendingActions.first?.conversationID == scopedID &&
                   legacyStore.snapshot.conversations.filter { $0.accountID == accountID && $0.id == scopedID }.count == 1,
                   "旧会话迁移失败：count=\(legacyStore.snapshot.conversations.count), selected=\(legacyStore.selectedConversationID ?? "nil"), expected=\(scopedID), actions=\(legacyStore.snapshot.pendingActions.map { $0.conversationID ?? "nil" })")
    }

    private static func verifyCodexStaleResults() throws {
        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-CodexFixture-\(UUID())")
            let release = root.appendingPathComponent("release")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let authHome = root.appendingPathComponent("auth-home")
                let isolatedService = CodexCLIService(codexHome: authHome)
                let environment = try await isolatedService.sanitizedEnvironment(tempDirectory: root)
                try verify(environment["CODEX_HOME"] == authHome.path &&
                           environment["OPENAI_API_KEY"] == nil && environment["CODEX_ACCESS_TOKEN"] == nil,
                           "Codex 继承了外部授权环境")
                let authExecutable = root.appendingPathComponent("auth-fixture")
                let otherAuth = root.appendingPathComponent("other-auth.json")
                try Data("unrelated".utf8).write(to: otherAuth)
                let authScript = """
                #!/bin/sh
                case "$*" in *'cli_auth_credentials_store="file"'*) ;; *) exit 9;; esac
                case "$1 $2" in
                  'login status') [ -f "$CODEX_HOME/auth.json" ]; exit $?;;
                  'logout '*) /bin/rm -f "$CODEX_HOME/auth.json"; exit 0;;
                esac
                if [ "$1" = login ]; then
                  while [ -f '\(root.path)/hold-login' ]; do /bin/sleep 0.05; done
                  printf 'fixture' > "$CODEX_HOME/auth.json"
                  exit 0
                fi
                exit 9
                """
                try Data(authScript.utf8).write(to: authExecutable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authExecutable.path)
                let initiallyAuthorized = try await isolatedService.isAuthorized(configuredPath: authExecutable.path)
                try verify(!initiallyAuthorized, "独立目录未登录却被视为已授权")
                try await isolatedService.authorize(configuredPath: authExecutable.path, onURL: { _ in })
                let newlyAuthorized = try await isolatedService.isAuthorized(configuredPath: authExecutable.path)
                try verify(newlyAuthorized, "授权后状态未更新")
                try await isolatedService.revokeAuthorization(configuredPath: authExecutable.path)
                let revoked = try await isolatedService.isAuthorized(configuredPath: authExecutable.path)
                let otherAuthData = try Data(contentsOf: otherAuth)
                try verify(!revoked && String(decoding: otherAuthData, as: UTF8.self) == "unrelated",
                           "退出未生效或影响其他授权")
                let holdLogin = root.appendingPathComponent("hold-login")
                try Data().write(to: holdLogin)
                let pendingLogin = Task { try await isolatedService.authorize(configuredPath: authExecutable.path, onURL: { _ in }) }
                try await Task.sleep(for: .milliseconds(250))
                try await isolatedService.revokeAuthorization(configuredPath: authExecutable.path)
                _ = await pendingLogin.result
                try FileManager.default.removeItem(at: holdLogin)
                let cancelledLoginAuthorized = try await isolatedService.isAuthorized(configuredPath: authExecutable.path)
                try verify(!cancelledLoginAuthorized, "取消登录后仍写入授权")
                print("CODEX independent authorization: login, logout, cancellation and unrelated credentials preserved")
                let modelExecutable = root.appendingPathComponent("model-fixture")
                let modelScript = """
                #!/bin/sh
                while IFS= read -r line; do
                  case "$line" in
                    *'"method":"initialize"'*) printf '%s\\n' '{"id":0,"result":{}}';;
                    *'"method":"model'*)
                      case "$line" in
                        *'"cursor":"next"'*) printf '%s\\n' '{"id":2,"result":{"data":[{"model":"fixture-deep","displayName":"Deep","defaultReasoningEffort":"xhigh","supportedReasoningEfforts":[{"reasoningEffort":"xhigh"}]}],"nextCursor":null}}';;
                        *) printf '%s\\n' '{"id":1,"result":{"data":[{"model":"fixture-fast","displayName":"Fast","defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low"}]},{"model":"hidden","hidden":true}],"nextCursor":"next"}}';;
                      esac;;
                  esac
                done
                """
                try Data(modelScript.utf8).write(to: modelExecutable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: modelExecutable.path)
                let catalog = try await isolatedService.models(configuredPath: modelExecutable.path, refresh: true)
                try verify(catalog.map(\.model) == ["fixture-fast", "fixture-deep"] &&
                           catalog.last?.supportedReasoningEfforts.map(\.reasoningEffort) == ["xhigh"],
                           "模型分页、隐藏项过滤或推理选项解析失败")
                try FileManager.default.removeItem(at: modelExecutable)
                let cachedCatalog = try await isolatedService.models(configuredPath: modelExecutable.path)
                try verify(cachedCatalog == catalog, "模型列表未复用本地缓存")
                try await isolatedService.revokeAuthorization(configuredPath: authExecutable.path)
                try verify(!FileManager.default.fileExists(atPath: authHome.appendingPathComponent("model-catalog.json").path),
                           "退出授权未清除模型目录缓存")
                var chosenConfiguration = CodexConfiguration()
                chosenConfiguration.model = "fixture-deep"
                chosenConfiguration.reasoningEffort = "xhigh"
                let restoredConfiguration = try JSONDecoder().decode(CodexConfiguration.self, from: JSONEncoder().encode(chosenConfiguration))
                try verify(restoredConfiguration == chosenConfiguration, "所选模型或推理强度未持久化")
                print("CODEX model catalog: pagination, hidden filtering, disk cache, logout cleanup and selected model persistence passed")
                let executable = root.appendingPathComponent("codex-fixture")
                let script = """
                #!/bin/sh
                if [ "$1" = "login" ] && [ "$2" = "status" ]; then exit 0; fi
                if [ "$1" = "--version" ]; then printf 'fixture 1.0\\n'; exit 0; fi
                if [ "$2" = "--help" ]; then printf '%s\\n' '--ephemeral --ignore-user-config --ignore-rules --disable'; exit 0; fi
                printf '%s\\n' "$@" > '\(root.path)/arguments'
                output=''
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "--output-last-message" ]; then shift; output="$1"; fi
                  shift
                done
                /bin/cat > '\(root.path)/prompt'
                printf '%s\\n' "$$" >> '\(root.path)/invocations'
                printf '%s' "$$" > '\(root.path)/started'
                if /usr/bin/grep -q '你是 BOSS 直聘检索计划生成器' '\(root.path)/prompt'; then
                  while [ -f '\(root.path)/hold-plan' ]; do /bin/sleep 0.02; done
                fi
                while [ -d '\(root.path)' ] && [ ! -f '\(release.path)' ]; do /bin/sleep 0.02; done
                /bin/cat '\(root.path)/payload' > "$output"
                exit "$(/bin/cat '\(root.path)/status')"
                """
                try Data(script.utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                let store = AppStore(persistence: JSONStatePersistence(fileURL: root.appendingPathComponent("state.json")))
                let attachment = root.appendingPathComponent("attachment.txt")
                try Data("isolated resume".utf8).write(to: attachment)
                store.updateResume {
                    $0.attachmentPath = attachment.path
                    $0.text = "有六年 Java 后端开发经验，负责企业业务系统建设。"
                    $0.profileSummary = "旧画像"
                    $0.suggestedSearchQueries = ["Java"]
                }
                store.updateCodex { $0.executablePath = executable.path; $0.allowJobDataToCodex = true; $0.enableReplyDrafting = true; $0.model = "fixture-deep"; $0.reasoningEffort = "xhigh" }
                let controller = CodexController()
                func prepare(_ payload: String, status: String = "0") throws {
                    try? FileManager.default.removeItem(at: release)
                    try? FileManager.default.removeItem(at: root.appendingPathComponent("started"))
                    try Data(payload.utf8).write(to: root.appendingPathComponent("payload"))
                    try Data(status.utf8).write(to: root.appendingPathComponent("status"))
                }
                @MainActor func waitStarted() async throws {
                    let deadline = Date().addingTimeInterval(5)
                    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), Date() < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try verify(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path),
                               "隔离 Codex CLI 未启动")
                    let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
                    try verify(arguments.contains("fixture-deep") && arguments.contains("model_reasoning_effort=\"xhigh\""),
                               "模型或推理强度未传给 Codex CLI")
                }
                func finish() throws { try Data().write(to: release) }

                try prepare("{}", status: "7")
                let profiling = Task { await controller.analyzeResume(using: store) }
                try await waitStarted()
                store.updateResume { $0.text = "现在从事 Python 数据工程"; $0.profileSummary = "新画像" }
                try finish()
                await profiling.value
                try verify(store.snapshot.resume.profileSummary == "新画像" && !controller.isProfilingResume,
                           "旧画像请求失败后的回退覆盖了同 ID 的新简历内容")

                func invocationCount() throws -> Int {
                    try String(contentsOf: root.appendingPathComponent("invocations"), encoding: .utf8)
                        .split(separator: "\n").count
                }
                let summary = "具备多年服务端开发经验，熟悉数据处理、系统设计和工程交付，适合 Python 数据平台开发及相关后端岗位。"
                let profilePayload = try String(decoding: JSONSerialization.data(withJSONObject: [
                    "profile_summary": summary, "search_queries": ["Python"], "cities": []
                ]), as: UTF8.self)
                try prepare(profilePayload)
                let firstProfile = Task { await controller.analyzeResume(using: store) }
                try await waitStarted()
                let profileCount = try invocationCount()
                store.updateResume { $0.text = "中间版本 Java 简历" }
                let supersededProfile = Task { await controller.analyzeResume(using: store) }
                try await Task.sleep(for: .milliseconds(20))
                store.updateResume { $0.text = "最终版本 Python 数据平台简历" }
                let latestProfile = Task { await controller.analyzeResume(using: store) }
                try await Task.sleep(for: .milliseconds(20))
                try finish()
                await firstProfile.value
                await supersededProfile.value
                await latestProfile.value
                let latestPrompt = try String(contentsOf: root.appendingPathComponent("prompt"), encoding: .utf8)
                let completedProfileCount = try invocationCount()
                try verify(store.snapshot.resume.profileSummary == summary && latestPrompt.contains("最终版本 Python") &&
                           completedProfileCount == profileCount + 1 && !controller.isProfilingResume,
                           "连续简历分析丢弃最新请求、执行中间请求或使用了旧输入")

                try prepare(profilePayload)
                let activeProfile = Task { await controller.analyzeResume(using: store) }
                try await waitStarted()
                let cancellationCount = try invocationCount()
                let cancelledProfile = Task { await controller.analyzeResume(using: store) }
                try await Task.sleep(for: .milliseconds(20))
                cancelledProfile.cancel()
                await cancelledProfile.value
                try finish()
                await activeProfile.value
                let afterCancellationCount = try invocationCount()
                try verify(afterCancellationCount == cancellationCount && !controller.isProfilingResume,
                           "取消等待中的分析请求仍启动了 CLI")

                let preservedProfile = store.snapshot.resume
                try prepare(profilePayload)
                let manuallyCancelled = Task { await controller.analyzeResume(using: store) }
                try await waitStarted()
                let profilePID = Int32(try String(contentsOf: root.appendingPathComponent("started"), encoding: .utf8))
                let cancelProfileAt = Date()
                controller.cancelResumeAnalysis()
                await manuallyCancelled.value
                try verify(Date().timeIntervalSince(cancelProfileAt) < 2 && !controller.isProfilingResume &&
                           controller.resumeAnalysisStartedAt == nil && store.snapshot.resume == preservedProfile,
                           "取消画像没有及时退出或覆盖了已有画像")
                if let profilePID { try verify(kill(profilePID, 0) != 0, "取消画像后 CLI 仍在运行") }
                try prepare("{}", status: "7")
                let failedRefresh = Task { await controller.analyzeResume(using: store) }
                try await waitStarted()
                try finish()
                await failedRefresh.value
                try verify(store.snapshot.resume == preservedProfile && controller.resumeAnalysisError != nil &&
                           !controller.isProfilingResume, "更新失败后旧画像被回退覆盖或加载状态未恢复")

                store.updatePreferences { $0.requirementText = "上海 Python 开发" }
                let holdPlan = root.appendingPathComponent("hold-plan")
                try Data().write(to: holdPlan)
                try prepare(profilePayload)
                let profileAndPlan = Task { await controller.analyzeResume(using: store) }
                try await waitStarted()
                try finish()
                let planDeadline = Date().addingTimeInterval(3)
                while !controller.isPlanningSearch, Date() < planDeadline { try await Task.sleep(for: .milliseconds(20)) }
                try verify(controller.isPlanningSearch && !controller.isProfilingResume &&
                           controller.resumeAnalysisStartedAt == nil && controller.resumeAnalysisError == nil &&
                           store.snapshot.resume.profileSummary == summary,
                           "画像已生成却仍等待检索计划才结束加载")
                try Data(#"{"queries":["Python"],"cities":["上海"]}"#.utf8).write(to: root.appendingPathComponent("payload"))
                try FileManager.default.removeItem(at: holdPlan)
                await profileAndPlan.value
                try verify(store.snapshot.preferences.plannedSearchQueries == ["Python"], "画像完成后未继续生成检索计划")
                print("CODEX profile refresh: manual cancellation stops process; failure keeps prior profile; planning has separate loading state")

                store.updatePreferences { $0.requirementText = "上海 Java 开发" }
                try prepare(#"{"queries":["Python"],"cities":["上海"]}"#)
                let oldPlan = Task { await controller.planSearch(using: store) }
                try await waitStarted()
                let planCount = try invocationCount()
                store.updatePreferences { $0.requirementText = "只考虑上海 Python 数据平台开发" }
                let replacementPlan = Task { await controller.planSearch(using: store) }
                try await Task.sleep(for: .milliseconds(20))
                oldPlan.cancel()
                await oldPlan.value
                try finish()
                await replacementPlan.value
                let completedPlanCount = try invocationCount()
                let planPrompt = try String(contentsOf: root.appendingPathComponent("prompt"), encoding: .utf8)
                try verify(completedPlanCount == planCount + 1 && planPrompt.contains("只考虑上海 Python") &&
                           store.snapshot.preferences.plannedSearchQueries == ["Python"] && !controller.isPlanningSearch,
                           "旧检索任务取消时丢失最新要求的检索请求")

                store.updatePreferences { $0.requirementText = "上海后端开发" }
                try prepare(#"{"queries":["Java"],"cities":["上海"]}"#)
                let planning = Task { await controller.planSearch(using: store) }
                try await waitStarted()
                store.updateResume { $0.profileSummary = "更新为数据平台方向"; $0.suggestedSearchQueries = ["Python"] }
                try finish()
                await planning.value
                try verify(store.snapshot.preferences.plannedSearchQueries.isEmpty && !controller.isPlanningSearch,
                           "基于旧画像的检索计划写回了新画像")
                try prepare(#"{"queries":["Python"],"cities":["上海"]}"#)
                let freshPlan = Task { await controller.planSearch(using: store) }
                try await waitStarted()
                try finish()
                await freshPlan.value
                try verify(store.snapshot.preferences.plannedSearchQueries == ["Python"], "有效检索计划被错误丢弃")

                let accountID = store.addBossAccount()
                var profile = BossAccountProfile()
                profile.remoteID = "fixture-geek"
                _ = try store.applyBossProfile(profile, accountID: accountID)
                store.synchronizeBossLoginStatus(accountID: accountID, loggedIn: true)
                store.updateAutomation { $0.allowRecruiterTextToCodex = true; $0.automaticallyDraftReplies = false }
                _ = store.upsertBossFriendSummaries([BossFriendSummary(conversationID: "fixture-chat",
                    recruiterName: "测试招聘方", company: "测试公司", jobTitle: "Java 开发", latestText: "",
                    unreadCount: 0, updatedAt: Date(), securityID: "fixture-security", listID: "")], accountID: accountID)
                let conversationID = try required(store.snapshot.conversations.first?.id, "隔离会话未创建")
                @MainActor func receive(_ text: String) {
                    _ = store.upsertBossHistoryMessages(messages: [BossResumeHistoryMessage(messageID: "100",
                        timestampMilliseconds: 1_700_000_000_000, messageType: 1, bodyType: 1, sanitizedText: text,
                        senderID: "fixture-recruiter", recipientID: profile.remoteID, isSelf: false,
                        actionID: nil, actionAnnexType: nil, actionScene: nil, actionWasOperated: nil,
                        dialogType: nil, dialogWasOperated: nil)], accountID: accountID, conversationID: conversationID)
                }
                let reply = #"{"intent":"question","confidence":0.95,"reason":"测试","reply":"明天可以沟通","should_create_resume_task":false}"#
                receive("明天方便沟通吗？")
                try prepare(reply)
                let drafting = Task { await controller.draftReply(conversationID: conversationID, using: store) }
                try await waitStarted()
                receive("你的薪资期望是多少？")
                try finish()
                await drafting.value
                try verify(store.snapshot.pendingActions.isEmpty && controller.draftingConversationIDs.isEmpty,
                           "同 MID 内容变更后仍写入旧回复草稿")

                try prepare(reply)
                let cancelled = Task { await controller.draftReply(conversationID: conversationID, using: store) }
                try await waitStarted()
                let processID = Int32(try String(contentsOf: root.appendingPathComponent("started"), encoding: .utf8))
                let cancelStartedAt = Date()
                await controller.cancelOperationsAndWait(accountID: accountID)
                await cancelled.value
                try verify(Date().timeIntervalSince(cancelStartedAt) < 2 && controller.draftingConversationIDs.isEmpty &&
                           store.snapshot.pendingActions.isEmpty, "取消 CLI 后进程或草稿任务仍在运行")
                if let processID { try verify(kill(processID, 0) != 0, "已取消 CLI 进程仍存活") }
                try prepare(reply)
                let freshDraft = Task { await controller.draftReply(conversationID: conversationID, using: store) }
                try await waitStarted()
                try finish()
                await freshDraft.value
                try verify(store.snapshot.pendingActions.contains { $0.kind == .sendMessage }, "取消后 CLI 仍繁忙或正常草稿无法生成")
                print("CODEX stale results discarded; latest profile and plan requests coalesced; cancelled waiters skipped; real fixture process cancelled; fresh results accepted")
                completion = .success(())
            } catch {
                try? Data().write(to: release)
                completion = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(35)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let completion else { task.cancel(); throw SelfCheckError.failed("Codex 延迟结果测试超时") }
        try completion.get()
    }

    private static func verifyHistoryBatch(snapshot: AppSnapshot, conversation: Conversation) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-HistoryBatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = snapshot
        fixture.pendingActions = []
        fixture.resumeDeliveryRecords = []
        fixture.resumeConsentSafetyRecords = []
        fixture.automation.automaticallySendResume = true
        fixture.automation.automaticallyDraftReplies = false
        var seed = try required(snapshot.conversations.first { $0.id == conversation.id }, "缺少消息压力测试会话")
        let seedMessage = try required(seed.messages.first { $0.direction == .incoming && $0.hasAuthoritativeDirection == true }, "缺少权威消息")
        seed.messages = []
        seed.unreadCount = 0
        fixture.conversations = (0..<120).map { index in
            var item = seed
            item.id = "history-load-\(index)"
            item.remoteConversationID = "history-remote-\(index)"
            item.messages = (0..<100).map { messageIndex in
                var message = seedMessage
                message.id = "history-message-\(index)-\(messageIndex)"
                message.remoteMID = String(10_000 + index * 100 + messageIndex)
                message.text = "你好"
                message.intent = .greeting
                return message
            }
            return item
        }
        let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
        try persistence.save(fixture)
        let store = AppStore(persistence: persistence)
        store.load()
        let target = fixture.conversations[0]
        let globalStart = Date()
        let expected = store.authoritativeResumeConsentCandidates(accountID: target.accountID).filter { $0.conversationID == target.id }
        let globalDuration = Date().timeIntervalSince(globalStart)
        let scopedStart = Date()
        let actual = store.authoritativeResumeConsentCandidates(accountID: target.accountID, conversationID: target.id)
        let scopedDuration = Date().timeIntervalSince(scopedStart)
        try verify(actual == expected, "会话范围证据检索改变了结果")
        func remote(_ id: String, text: String = "你好") -> BossResumeHistoryMessage {
            BossResumeHistoryMessage(messageID: id, timestampMilliseconds: 1_900_000_000_000,
                messageType: 1, bodyType: 1, sanitizedText: text, senderID: seedMessage.remoteSenderID,
                recipientID: seedMessage.remoteRecipientID, isSelf: false, actionID: nil, actionAnnexType: nil,
                actionScene: nil, actionWasOperated: nil, dialogType: nil, dialogWasOperated: nil)
        }
        let batch = (0..<500).map { remote(String(1_000_000 + $0)) }
        var publications = 0
        let observer = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observer.cancel() }
        let startedAt = Date()
        let inserted = store.upsertBossHistoryMessages(messages: batch, accountID: target.accountID, conversationID: target.id)
        let duration = Date().timeIntervalSince(startedAt)
        try verify(inserted.insertedMessageCount == 500 && publications == 1, "历史批次丢失消息或逐条发布完整状态")
        let repeated = store.upsertBossHistoryMessages(messages: batch, accountID: target.accountID, conversationID: target.id)
        try verify(repeated.insertedMessageCount == 0 && repeated.refreshedMessageCount == 0, "历史批次重复入库")
        let empty = store.upsertBossHistoryMessages(messages: [], accountID: target.accountID, conversationID: target.id)
        try verify(empty.insertedMessageCount == 0 && empty.authoritativeConsentCount == 0 &&
                   store.snapshot.conversations.first { $0.id == target.id }?.unreadCount == 500,
                   "空历史页改变了消息、同意证据或未读数")
        let orderTarget = fixture.conversations[1]
        let ids = ["9", "10000000000000000000000000000000", "10"]
        let ordered = store.upsertBossHistoryMessages(messages: ids.map { remote($0, text: "方便沟通吗？") },
                                                     accountID: target.accountID, conversationID: orderTarget.id)
        let saved = try required(store.snapshot.conversations.first { $0.id == orderTarget.id }, "排序测试会话丢失")
        try verify(Array(saved.messages.suffix(3)).map(\.remoteMID) == ["9", "10", ids[1]] && ordered.newestRemoteMID == ids[1],
                   "相同时间戳消息按字符串而非数值 MID 排序，或最新 MID 取决于输入顺序")
        store.flush()
        let reloaded = try persistence.load()
        try verify(reloaded.conversations.first { $0.id == target.id }?.messages.count == 600, "批量历史未完整持久化")
        print(String(format: "PERF history 120 conversations / 12000 messages: global evidence %.1f ms, scoped %.1f ms; 500-message merge %.1f ms, one snapshot publication", globalDuration * 1000, scopedDuration * 1000, duration * 1000))
    }

    private static func verifyWebRequestIsolation() throws {
        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            do {
                let profileID = UUID()
                BossWebSessionService.beginRetiring(profileID: profileID)
                let client = BossWebAPIClient(profileID: profileID)
                defer { client.invalidate() }
                let url = OfficialBossLinkService.jobs
                // CSP blocks accidental network access; fetch only resolves from this test.
                client.webView.loadHTMLString("""
                    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'">
                    <script>window.pendingResponses = []; window.fetch = () => new Promise(resolve => pendingResponses.push(resolve));</script>
                    """, baseURL: url)
                let readyDeadline = Date().addingTimeInterval(10)
                while client.requiresPreparation(at: url), Date() < readyDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try verify(!client.requiresPreparation(at: url), "隔离 WebKit 页面未就绪")
                let request = BossWebAPIRequest(url: url, method: .GET)
                let first = Task { try await client.requestJSONData(request: request) }
                try await Task.sleep(for: .milliseconds(100))
                do {
                    _ = try await client.requestJSONData(request: request)
                    throw SelfCheckError.failed("并发网页请求覆盖了已有等待器")
                } catch BossWebAPIError.requestInProgress {}
                do {
                    try await client.prepare(at: URL(string: "https://www.zhipin.com/web/geek/chat")!)
                    throw SelfCheckError.failed("请求执行中仍允许导航切换")
                } catch BossWebAPIError.requestInProgress {}
                _ = try await client.webView.evaluateJavaScript("""
                    window.webkit.messageHandlers.bossPilotReadBridge.postMessage(JSON.stringify({id:'stale-request',status:200,body:'wrong'}));
                    pendingResponses.shift()({status:200,text:async ()=>'first'}); null
                    """)
                let firstData = try await first.value
                try verify(String(decoding: firstData, as: UTF8.self) == "first", "迟到回包污染了当前请求")

                let rejected = Task { try await client.requestJSONData(request: request) }
                try await Task.sleep(for: .milliseconds(100))
                _ = try await client.webView.evaluateJavaScript("pendingResponses.shift()({status:503,text:async ()=>'unavailable'}); null")
                do {
                    _ = try await rejected.value
                    throw SelfCheckError.failed("网页请求忽略了 HTTP 错误")
                } catch BossWebAPIError.httpStatus(503) {}
                let recovered = Task { try await client.requestJSONData(request: request) }
                try await Task.sleep(for: .milliseconds(100))
                _ = try await client.webView.evaluateJavaScript("pendingResponses.shift()({status:200,text:async ()=>'recovered'}); null")
                let recoveredData = try await recovered.value
                try verify(String(decoding: recoveredData, as: UTF8.self) == "recovered", "HTTP 错误后无法继续请求")

                let timedOutBrowser = client.webView!
                let timeoutStartedAt = Date()
                do {
                    _ = try await client.requestJSONData(request: request)
                    throw SelfCheckError.failed("无回包请求没有超时")
                } catch BossWebAPIError.pageLoadTimedOut {}
                let timeoutDuration = Date().timeIntervalSince(timeoutStartedAt)
                try verify(client.isInvalidated && timeoutDuration >= 19 && timeoutDuration < 23,
                           "请求超时未退出或仍复用旧消息桥")
                do {
                    _ = try await client.requestJSONData(request: request)
                    throw SelfCheckError.failed("超时客户端接受了后续请求")
                } catch is CancellationError {}
                let handlerRemoved = try await timedOutBrowser.evaluateJavaScript(
                    "!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.bossPilotReadBridge"
                ) as? Bool
                try verify(handlerRemoved == true && client.webView == nil, "超时后消息桥仍可投递迟到回包或客户端仍持有网页")
                print(String(format: "WEBKIT concurrent request rejected; stale response ignored; HTTP recovery passed; timeout retired client in %.2f s", timeoutDuration))
                completion = .success(())
            } catch {
                completion = .failure(SelfCheckError.failed("WebKit 隔离测试失败：\(error) \((error as NSError).userInfo)"))
            }
        }
        let deadline = Date().addingTimeInterval(40)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let completion else {
            task.cancel()
            throw SelfCheckError.failed("网页请求隔离回归测试超时")
        }
        try completion.get()
    }

    private static func verifyAccountCancellation() throws {
        var completion: Result<Void, Error>?
        let task = Task { @MainActor in
            do {
                let gate = BossNetworkPacingGate()
                let epochs = BossRequestEpochGate()
                let accountID = UUID()
                let token = epochs.token(accountID: accountID)
                try await gate.wait(isWrite: false, discriminator: "test-prime")
                let primedAt = Date()
                let queuedWrite = Task {
                    try await gate.wait(isWrite: true, discriminator: "test-delete-write", isStillValid: {
                        epochs.isCurrent(accountID: accountID, token: token)
                    })
                }
                try await Task.sleep(for: .milliseconds(50))
                let cancelledAt = Date()
                epochs.invalidate(accountID: accountID)
                do {
                    try await queuedWrite.value
                    throw SelfCheckError.failed("已删除账号的排队写操作仍获得发送许可")
                } catch is CancellationError {}
                let cancellationDuration = Date().timeIntervalSince(cancelledAt)
                try verify(cancellationDuration < 1, "失效请求仍在等待完整限速间隔")

                let cancelledRead = Task { try await gate.wait(isWrite: false, discriminator: "test-cancel") }
                cancelledRead.cancel()
                do {
                    try await cancelledRead.value
                    throw SelfCheckError.failed("任务取消没有终止限速等待")
                } catch is CancellationError {}
                let readStartedAt = Date()
                try await gate.wait(isWrite: false, discriminator: "test-other-account")
                let readDelay = Date().timeIntervalSince(readStartedAt)
                let timeSincePrime = Date().timeIntervalSince(primedAt)
                try verify(
                    timeSincePrime >= BossRequestPacingPolicy.minimumReadIntervalSeconds - 0.1 &&
                    readDelay < BossRequestPacingPolicy.minimumReadIntervalSeconds +
                        TimeInterval(BossRequestPacingPolicy.maximumReadJitterSeconds) + 1,
                    "取消写操作后读请求被饿死或绕过限速"
                )

                let clientProfile = UUID()
                BossWebSessionService.beginRetiring(profileID: clientProfile)
                var client: BossWebAPIClient? = BossWebAPIClient(profileID: clientProfile)
                weak var releasedClient = client
                client?.invalidate()
                do {
                    try await client?.prepare(at: OfficialBossLinkService.jobs)
                    throw SelfCheckError.failed("失效网页客户端重新开始加载页面")
                } catch is CancellationError {}
                do {
                    _ = try await client?.requestJSONData(request: BossWebAPIRequest(url: OfficialBossLinkService.jobs, method: .GET))
                    throw SelfCheckError.failed("失效网页客户端仍可发送请求")
                } catch is CancellationError {}
                client = nil
                try verify(releasedClient == nil, "网页消息桥仍强引用已删除客户端")
                do {
                    _ = try await BossWebAPIService().requestJSONData(
                        profileID: UUID(), request: BossWebAPIRequest(url: OfficialBossLinkService.jobs, method: .POST),
                        warmupURL: OfficialBossLinkService.jobs, isStillValid: { false }
                    )
                    throw SelfCheckError.failed("请求跨 actor 排队时失效仍可启动网页客户端")
                } catch is CancellationError {}

                // 使用真实 WebKit 服务验证预热排队，随机 Profile 不包含登录和用户数据。
                try await BossNetworkPacingGate.shared.wait(isWrite: false, discriminator: "test-web-prime")
                let queuedProfile = UUID()
                BossWebSessionService.beginRetiring(profileID: queuedProfile)
                let webService = BossWebAPIService()
                let queuedWebRequest = Task {
                    try await webService.requestJSONData(
                        profileID: queuedProfile,
                        request: BossWebAPIRequest(url: OfficialBossLinkService.jobs, method: .GET),
                        warmupURL: OfficialBossLinkService.jobs
                    )
                }
                try await Task.sleep(for: .milliseconds(50))
                let webCancelledAt = Date()
                webService.forget(profileID: queuedProfile)
                do {
                    _ = try await queuedWebRequest.value
                    throw SelfCheckError.failed("删除后排队网页请求仍成功返回")
                } catch is CancellationError {}
                let webCancellationDuration = Date().timeIntervalSince(webCancelledAt)
                try verify(webCancellationDuration < 1, "网页请求失效后仍阻塞删除")

                // 请求停留在调度队列中，不产生网络访问。
                let siblingAPI = BossAPIService()
                let siblingAccount = UUID()
                let siblingProfile = UUID()
                BossWebSessionService.beginRetiring(profileID: siblingProfile)
                let cancelledSibling = Task {
                    try await siblingAPI.jobDetail(accountID: siblingAccount, profileID: siblingProfile,
                        credential: BossCredential(cookies: []), requestToken: 0,
                        securityID: "test-sibling", listID: "")
                }
                var remainingSiblingFinished = false
                let remainingSibling = Task { @MainActor in
                    defer { remainingSiblingFinished = true }
                    return try await siblingAPI.jobDetail(accountID: siblingAccount, profileID: siblingProfile,
                        credential: BossCredential(cookies: []), requestToken: 0,
                        securityID: "test-remaining", listID: "")
                }
                try await Task.sleep(for: .milliseconds(50))
                cancelledSibling.cancel()
                do {
                    _ = try await cancelledSibling.value
                    throw SelfCheckError.failed("API 兄弟请求未被取消")
                } catch is CancellationError {}
                await siblingAPI.cancelActiveRequests(accountID: siblingAccount)
                let siblingDeadline = Date().addingTimeInterval(1)
                while !remainingSiblingFinished, Date() < siblingDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let cancellationReachedSibling = remainingSiblingFinished
                remainingSibling.cancel()
                do {
                    _ = try await remainingSibling.value
                    throw SelfCheckError.failed("账号取消后剩余 API 请求仍返回结果")
                } catch is CancellationError {}
                try verify(cancellationReachedSibling, "先结束的兄弟请求清除了账号注册，导致剩余请求无法取消")

                let exchange = BossResumeExchangeService.shared
                let networkController = BossAutomationController(
                    api: BossAPIService(allowsWebFallback: false), resumeExchange: exchange
                )
                let operationAccount = UUID()
                let operationProfile = UUID()
                BossWebSessionService.beginRetiring(profileID: operationProfile)
                let operationGeneration = try required(networkController.beginOperation(
                    accountID: operationAccount, profileID: operationProfile
                ), "无法启动隔离网络操作")
                let otherAccount = UUID()
                let otherGeneration = try required(networkController.beginOperation(
                    accountID: otherAccount, profileID: UUID()
                ), "无法启动另一账号操作")
                let historyTask = Task { @MainActor in
                    defer { networkController.finishOperation(accountID: operationAccount, generation: operationGeneration) }
                    return try await exchange.history(profileID: operationProfile, query: BossResumeHistoryQuery(
                        bossID: "test-boss", maximumMessageID: "0", count: 20, page: 1,
                        source: 0, securityID: "test-security"
                    ))
                }
                try await Task.sleep(for: .milliseconds(50))
                let controllerCancelledAt = Date()
                networkController.invalidateOperations(accountID: operationAccount)
                try await networkController.cancelInvalidatedOperationsAndWait(accountID: operationAccount)
                do {
                    _ = try await historyTask.value
                    throw SelfCheckError.failed("未同步消息的账号删除后仍完成历史请求")
                } catch is CancellationError {
                } catch BossResumeExchangeError.serviceInvalidated {}
                let controllerCancellationDuration = Date().timeIntervalSince(controllerCancelledAt)
                try verify(controllerCancellationDuration < 1 && networkController.runningAccountIDs == [otherAccount],
                           "控制器取消遗漏开聊客户端或停止了其他账号")
                networkController.finishOperation(accountID: otherAccount, generation: otherGeneration)

                let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-Delete-\(UUID())")
                defer { try? FileManager.default.removeItem(at: root) }
                let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
                let store = AppStore(persistence: persistence)
                let deletedID = store.addBossAccount()
                let retainedID = store.addBossAccount()
                let account = try required(store.snapshot.accounts.first { $0.id == deletedID }, "隔离账号未创建")
                let vault = BossCredentialVault(directoryURL: root.appendingPathComponent("Sessions"))
                let fixtureCookies = try ["wt2", "zp_at"].map { name in
                    try required(HTTPCookie(properties: [
                        .name: name, .value: "isolated-deletion-fixture", .domain: ".zhipin.com", .path: "/"
                    ]), "无法创建隔离测试 Cookie")
                }
                try vault.save(BossCredential(cookies: fixtureCookies), profileID: account.webProfileID)
                await BossWebSessionService.importCookies(fixtureCookies, profileID: account.webProfileID)
                let seededCookies = await BossWebSessionService.cookies(profileID: account.webProfileID)
                try verify(seededCookies.contains { $0.name == "wt2" }, "持久 WebKit 测试数据未写入")
                let heldClient = BossWebAPIClient(profileID: account.webProfileID)
                let browserView = BossWebView(controller: BossBrowserController(profileID: account.webProfileID),
                    initialURL: URL(string: "about:blank")!, onCookiesChanged: { _ in })
                let browserCoordinator = browserView.makeCoordinator()
                let retainedContainer = browserView.makeBrowserContainer(coordinator: browserCoordinator)
                weak var mountedBrowser = browserCoordinator.webView
                try verify(mountedBrowser != nil, "删除回归未挂载真实 WebView")
                let session = BossAccountSessionController(accountID: deletedID, profileID: account.webProfileID,
                    allowsCredentialRestore: false, credentialVault: vault)
                let controller = BossAutomationController(api: BossAPIService(allowsWebFallback: false))
                controller.invalidateOperations(accountID: deletedID)
                try store.beginAccountDeletion(id: deletedID)
                session.beginDeletionBarrier()
                session.reportRemovalFailure(BossAutomationError.operationCancellationTimedOut)
                session.beginDeletionBarrier()
                let deletionStartedAt = Date()
                try await controller.cancelInvalidatedOperationsAndWait(accountID: deletedID)
                try await session.removeLocalData()
                let remainingCookies = await BossWebSessionService.cookies(profileID: account.webProfileID)
                let remainingCredential = try vault.load(profileID: account.webProfileID)
                try verify(remainingCookies.isEmpty && remainingCredential == nil, "删除未清理 Cookie 或会话文件")
                BossWebSessionService.releaseCachedStore(for: account.webProfileID)
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: account.webProfileID)
                    throw SelfCheckError.failed("已挂载网页未复现数据存储占用")
                } catch let error as NSError where error.domain == "WKWebSiteDataStore" {
                    try verify(error.localizedDescription == "Data store is in use", "WebKit 返回了非占用错误")
                }
                let busyStartedAt = Date()
                do {
                    try await BossWebSessionService.removePersistentStore(for: account.webProfileID)
                    throw SelfCheckError.failed("持续占用的数据存储被误报为删除成功")
                } catch BossWebSessionError.storeStillInUse {}
                try verify(Date().timeIntervalSince(busyStartedAt) >= 3 && Date().timeIntervalSince(busyStartedAt) < 5,
                    "数据存储占用重试没有按时结束")
                let cancelledRemoval = Task { @MainActor in
                    try await BossWebSessionService.removePersistentStore(for: account.webProfileID)
                }
                try await Task.sleep(for: .milliseconds(50))
                cancelledRemoval.cancel()
                do {
                    try await cancelledRemoval.value
                    throw SelfCheckError.failed("取消后仍继续删除重试")
                } catch is CancellationError {}
                heldClient.invalidate()
                try verify(heldClient.webView == nil, "失效客户端仍持有 WebView")
                let unmountTask = Task { @MainActor in
                    try await Task.sleep(for: .milliseconds(650))
                    BossWebView.dismantleNSView(retainedContainer, coordinator: browserCoordinator)
                }
                defer { unmountTask.cancel() }
                let removalStartedAt = Date()
                try await BossWebSessionService.removePersistentStore(for: account.webProfileID)
                try await unmountTask.value
                try verify(Date().timeIntervalSince(removalStartedAt) >= 0.6,
                    "持久存储尚未释放就提前报告删除成功")
                try verify(retainedContainer.subviews.isEmpty && mountedBrowser == nil,
                    "SwiftUI 容器仍保留已卸载的 WebView")
                let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
                try verify(!identifiers.contains(account.webProfileID), "删除后 WebKit 仍登记目标持久存储")
                try verify(heldClient.isInvalidated, "删除测试未保留失效客户端引用")
                print("DELETE active WebView reproduced Data store is in use; delayed unmount recovered; retained client and container released browser; persistent identifier removed")
                try store.removeAccount(id: deletedID)
                session.finalizeRemoval()
                let restored = try persistence.load()
                try verify(restored.accounts.map(\.id) == [retainedID], "删除重试未持久化或删除了其他账号")
                try await session.removeLocalData()
                print(String(format: "DELETE cancellation %.0f ms; WebKit queued cancellation %.0f ms; controller cancellation %.0f ms; isolated deletion retry %.0f ms; unrelated read preserved %.1f s",
                    cancellationDuration * 1000, webCancellationDuration * 1000, controllerCancellationDuration * 1000,
                    Date().timeIntervalSince(deletionStartedAt) * 1000, readDelay))
                completion = .success(())
            } catch {
                completion = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(25)
        while completion == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let completion else {
            task.cancel()
            throw SelfCheckError.failed("账号删除异步回归测试超时")
        }
        try completion.get()
    }

    private static func verifySentResumeJobClassification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-Exchange-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
        var account = BossAccount(displayName: "交换测试账号")
        account.remoteProfile = BossAccountProfile(remoteID: "exchange-fixture-owner")
        let accountID = account.id
        let attachmentSentAt = Date(timeIntervalSince1970: 1_700_001_000)
        var sent = ChatMessage(id: "sent-card", direction: .incoming,
            text: "您的附件简历 测试简历.pdf 已发送给Boss点击查看附件", sentAt: attachmentSentAt, intent: nil, confidence: nil)
        sent.isAuthoritativeHistoryRecord = true
        sent.hasAuthoritativeDirection = true
        sent.remoteMID = "101"
        sent.remoteMessageType = 3
        sent.remoteBodyType = 12
        var viewed = sent
        viewed.text = "对方已查看了您的附件简历"
        viewed.remoteMessageType = 4
        viewed.remoteBodyType = 1
        viewed.sentAt = attachmentSentAt.addingTimeInterval(300)
        var summary = sent
        summary.remoteMID = nil
        summary.direction = .system
        summary.isAuthoritativeHistoryRecord = false
        summary.hasAuthoritativeDirection = false
        var outgoing = sent
        outgoing.direction = .outgoing
        outgoing.text = "附件"
        outgoing.hyperLinkType = 1
        outgoing.hyperLinkResumeToken = "fixture-token"
        for message in [sent, viewed, summary, outgoing] {
            try verify(message.showsSentResumeAttachment, "附件发送或查看记录未计入已交换")
        }
        try verify(sent.resumeAttachmentSentAt == attachmentSentAt && summary.resumeAttachmentSentAt == attachmentSentAt &&
                   outgoing.resumeAttachmentSentAt == attachmentSentAt && viewed.resumeAttachmentSentAt == nil,
                   "附件发送时间丢失，或将稍后的附件查看时间误作交换时间")
        var request = sent
        request.text = "我想要一份您的附件简历，您是否同意"
        var ordinaryText = sent
        ordinaryText.remoteMessageType = 1
        ordinaryText.remoteBodyType = 1
        var revoked = sent
        revoked.hasAuthoritativeDirection = false
        var failed = sent
        failed.text = "您的附件简历 测试简历.pdf 发送失败"
        var claimedSent = ordinaryText
        claimedSent.direction = .outgoing
        claimedSent.text = "我已经发送简历了"
        for message in [request, ordinaryText, revoked, failed, claimedSent] {
            try verify(!message.showsSentResumeAttachment, "请求、普通文字或失败被误判为已交换")
        }
        var job = JobListing(id: "boss-manual-job", accountID: accountID, title: "Java 研发", company: "示例公司")
        job.securityID = "new-job-route"
        job.recruiterName = "示例招聘经理"
        let conversation = Conversation(id: "boss-manual-conversation", accountID: accountID,
            securityID: "old-chat-route", recruiterName: "示例招聘经理", company: "示例公司", jobTitle: "Java 研发",
            messages: [sent, viewed], unreadCount: 0, lastSyncedAt: Date(), sourceURL: "https://www.zhipin.com/web/geek/chat")
        var fixture = AppSnapshot()
        fixture.accounts = [account]
        fixture.jobs = [job]
        fixture.conversations = [conversation]
        try persistence.save(fixture)
        let store = AppStore(persistence: persistence)
        store.load()
        try verify(store.hasResumeExchange(for: job), "无工具投递记录的手动附件或更新路由未归入已交换")
        try verify(store.resumeExchangeDate(for: job) == attachmentSentAt, "手动附件发送时间未关联到岗位，或误取查看时间")
        var other = job
        other.recruiterName = "其他招聘方"
        try verify(!store.hasResumeExchange(for: other), "同公司同岗位但不同招聘方被串联")
        other = job
        other.accountID = UUID()
        try verify(!store.hasResumeExchange(for: other), "手动发送附件跨账号串联")
        try verify(store.resumeExchangeDate(for: other) == nil, "交换时间跨账号串联")
        other = job
        other.title = "Python 研发"
        try verify(!store.hasResumeExchange(for: other), "不同岗位被串联")
        store.removeConversation(id: conversation.id)
        try verify(!store.hasResumeExchange(for: job), "移除会话后手动附件索引未失效")
        try verify(store.resumeExchangeDate(for: job) == nil, "移除会话后仍显示过期的交换时间")
        var undated = job
        undated.stage = .resumeSent
        try verify(store.hasResumeExchange(for: undated) && store.resumeExchangeDate(for: undated) == nil,
                   "缺少发送时间的旧记录被补上了虚构时间，或丢失已交换状态")
        store.flush()
        let reloaded = AppStore(persistence: persistence)
        reloaded.load()
        try verify(!reloaded.hasResumeExchange(for: job), "删除记录后重载又恢复了错误的交换状态")
    }

    private static func verifyListPerformance(
        snapshot: AppSnapshot, conversation: Conversation, job: JobListing, record: ResumeDeliveryRecord
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BossPilot-Lists-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = JSONStatePersistence(fileURL: root.appendingPathComponent("state.json"))
        var fixture = snapshot
        fixture.jobs = []
        fixture.conversations = []
        fixture.resumeDeliveryRecords = []
        fixture.pendingActions = []
        for index in 0..<240 {
            var item = conversation
            item.id = "boss-perf-\(index)"
            item.remoteConversationID = "perf-remote-\(index)"
            item.securityID = "perf-security-\(index)"
            item.company = "测试公司 \(index)"
            item.jobTitle = "Java 研发 \(index)"
            item.remoteUpdatedAt = Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            item.lastSyncedAt = Date(timeIntervalSince1970: Double(1_800_000_000 - index))
            item.unreadCount = 0
            item.messages = []
            item.handledAt = nil
            fixture.conversations.append(item)
            var delivery = record
            delivery.id = "perf-record-\(index)"
            delivery.conversationID = index.isMultiple(of: 2) ? item.id : item.remoteConversationID!
            delivery.triggerRemoteMID = String(900_000 + index)
            fixture.resumeDeliveryRecords.append(delivery)
            for offset in 0..<5 {
                var listing = job
                listing.id = "boss-perf-job-\(index)-\(offset)"
                listing.company = item.company
                listing.title = item.jobTitle
                listing.securityID = offset == 4 ? "unmatched-\(index)" : item.securityID
                if offset == 4 { listing.title = "不同岗位 \(index)" }
                fixture.jobs.append(listing)
            }
        }
        try persistence.save(fixture)
        let store = AppStore(persistence: persistence)
        store.load()
        try verify(!store.persistenceBlocked && store.snapshot.resumeDeliveryRecords.count == 240,
                   "大列表测试数据加载失败")
        let jobs = store.snapshot.jobs
        let start = Date()
        let expected = jobs.map { listing in
            store.snapshot.resumeDeliveryRecords.contains { delivery in
                guard delivery.accountID == listing.accountID, delivery.state.countsAsResumeExchange,
                      let item = store.snapshot.conversations.first(where: {
                          $0.accountID == delivery.accountID &&
                          ($0.id == delivery.conversationID || $0.remoteConversationID == delivery.conversationID)
                      }) else { return false }
                // 测试路由均非空，旧匹配器应按完整路由匹配。
                return item.securityID == listing.securityID
            }
        }
        let legacyDuration = Date().timeIntervalSince(start)
        let indexedStart = Date()
        let actual = jobs.map { store.hasResumeExchange(for: $0) }
        let indexedDuration = Date().timeIntervalSince(indexedStart)
        let warmStart = Date()
        for _ in 0..<10 { for listing in jobs { _ = store.hasResumeExchange(for: listing) } }
        let warmDuration = Date().timeIntervalSince(warmStart)
        try verify(warmDuration < 0.25, "已交换岗位重复读取仍重复执行文字匹配")
        print(String(format: "PERF exchange index: cold %.1f ms; 12000 cached reads %.1f ms", indexedDuration * 1000, warmDuration * 1000))
        try verify(actual == expected && actual.filter { $0 }.count == 960,
                   "索引匹配改变了岗位归类或本地/远端会话别名匹配")
        var fallbackJob = jobs[0]
        fallbackJob.securityID = nil
        try verify(store.hasResumeExchange(for: fallbackJob), "缺少岗位路由时未保留文本匹配")
        fallbackJob.recruiterName = "different recruiter"
        try verify(!store.hasResumeExchange(for: fallbackJob), "文本匹配未核对招聘方")
        var foreignJob = jobs[0]
        foreignJob.accountID = UUID()
        try verify(!store.hasResumeExchange(for: foreignJob), "已交换索引跨账号泄漏")
        store.removeConversation(id: "boss-perf-0")
        let removedRouteJob = try required(jobs.first { $0.securityID == "perf-security-0" }, "缺少测试岗位")
        try verify(!store.hasResumeExchange(for: removedRouteJob), "删除会话后已交换缓存未失效")

        let ordered = ConversationPolicy.displayOrder(fixture.conversations, actions: [], deliveryRecords: [])
        try verify(ordered.first?.conversation.id == "boss-perf-239" && ordered.last?.conversation.id == "boss-perf-0",
                   "会话列表按同步时间而非消息时间排序")
        let tied = [fixture.conversations[0], fixture.conversations[0]]
        try verify(ConversationPolicy.displayOrder(tied, actions: [], deliveryRecords: []).count == 2,
                   "重复 ID 导致列表处理崩溃或丢失数据")
        var attention = fixture.conversations[0]
        attention.unreadCount = 1
        attention.messages = [ChatMessage(id: "question", direction: .incoming, text: "什么时候方便面试？",
                                          sentAt: Date(), intent: nil, confidence: nil)]
        let priority = ConversationPolicy.displayOrder([fixture.conversations[239], attention], actions: [], deliveryRecords: [])
        try verify(priority.first?.conversation.id == attention.id && priority.first?.state == .pending,
                   "待处理消息不再优先展示")
        attention.messages.append(ChatMessage(id: "empty", direction: .system, text: " \n ",
                                             sentAt: Date(), intent: nil, confidence: nil))
        try verify(attention.latestMessage?.id == "question", "空白消息覆盖了最近可显示消息")
        print(String(format: "PERF 1200 jobs / 240 conversations: legacy %.1f ms, indexed %.1f ms", legacyDuration * 1000, indexedDuration * 1000))

        let messageCases = (0..<180).map { index in
            var item = fixture.conversations[(index * 97) % 240]
            item.lastSyncedAt = item.latestActivityAt
            item.messages = [ChatMessage(id: "consent", direction: .incoming, text: "可以聊一聊",
                                        sentAt: item.lastSyncedAt, intent: nil, confidence: nil)]
            return item
        }
        let sortStart = Date()
        let oldOrder = messageCases.sorted { lhs, rhs in
            let left = ConversationPolicy.workState(for: lhs, actions: [], deliveryRecords: []) == .pending
            let right = ConversationPolicy.workState(for: rhs, actions: [], deliveryRecords: []) == .pending
            if left != right { return left }
            if lhs.unreadCount != rhs.unreadCount { return lhs.unreadCount > rhs.unreadCount }
            return lhs.lastSyncedAt > rhs.lastSyncedAt
        }
        let repeatedSortDuration = Date().timeIntervalSince(sortStart)
        let displayStart = Date()
        let newOrder = ConversationPolicy.displayOrder(messageCases, actions: [], deliveryRecords: [])
        let displayDuration = Date().timeIntervalSince(displayStart)
        try verify(oldOrder.map(\.id) == newOrder.map(\.conversation.id), "会话排序优化改变了相同时间口径下的顺序")
        print(String(format: "PERF 180 conversations: repeated classification %.1f ms, precomputed %.1f ms", repeatedSortDuration * 1000, displayDuration * 1000))

        let batchPersistence = JSONStatePersistence(fileURL: root.appendingPathComponent("batch.json"))
        let batchStore = AppStore(persistence: batchPersistence)
        let batch = fixture.jobs.enumerated().map { index, listing in
            var item = listing
            item.remoteJobID = "batch-remote-\(index)"
            return item
        }
        var publications = 0
        let observation = batchStore.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let insertStartedAt = Date()
        batchStore.upsertJobs(batch)
        let insertDuration = Date().timeIntervalSince(insertStartedAt)
        try verify(publications == 1 && batchStore.snapshot.jobs.count == batch.count,
                   "批量新增岗位逐条发布状态或丢失岗位")
        publications = 0
        let updates = batch.map { listing in
            var item = listing
            item.id += "-rotated"
            return item
        }
        let updateStartedAt = Date()
        batchStore.upsertJobs(updates)
        let updateDuration = Date().timeIntervalSince(updateStartedAt)
        try verify(publications == 1 && batchStore.snapshot.jobs.count == batch.count &&
                   Set(batchStore.snapshot.jobs.map(\.id)) == Set(updates.map(\.id)),
                   "批量更新逐条发布、重复插入或遗漏远端岗位身份迁移")
        publications = 0
        batchStore.upsertJobs([])
        try verify(publications == 0, "空批次仍触发列表刷新")
        var foreignListing = updates[0]
        foreignListing.id = "foreign-account-job"
        foreignListing.accountID = UUID()
        batchStore.upsertJobs([foreignListing])
        try verify(batchStore.snapshot.jobs.count == batch.count + 1, "远端岗位去重跨账号合并")
        batchStore.flush()
        let reloadedBatch = try batchPersistence.load()
        try verify(Set(reloadedBatch.jobs.map(\.id)) == Set(batchStore.snapshot.jobs.map(\.id)),
                   "批量岗位更新未完整持久化")
        print(String(format: "PERF 1200-job batch: insert %.1f ms, update %.1f ms; one snapshot publication each; empty batch zero", insertDuration * 1000, updateDuration * 1000))

        // 本地 ID 与远端 ID 可能指向不同旧记录，优先关联最早的一条。
        var duplicateFixture = AppSnapshot()
        var firstDuplicate = batch[0]
        firstDuplicate.id = "legacy-first"
        var secondDuplicate = firstDuplicate
        secondDuplicate.id = "legacy-second"
        secondDuplicate.remoteJobID = "legacy-other-remote"
        duplicateFixture.jobs = [firstDuplicate, secondDuplicate]
        let duplicatePersistence = JSONStatePersistence(fileURL: root.appendingPathComponent("duplicates.json"))
        try duplicatePersistence.save(duplicateFixture)
        let duplicateStore = AppStore(persistence: duplicatePersistence)
        duplicateStore.load()
        var conflicting = firstDuplicate
        conflicting.id = secondDuplicate.id
        conflicting.capturedAt = Date(timeIntervalSince1970: 2_000_000_000)
        var rotated = conflicting
        rotated.remoteJobID = "legacy-rotated-remote"
        rotated.capturedAt = conflicting.capturedAt.addingTimeInterval(1)
        duplicateStore.upsertJobs([conflicting, rotated])
        try verify(duplicateStore.snapshot.jobs.count == 2 &&
                   duplicateStore.snapshot.jobs[0].remoteJobID == "legacy-rotated-remote" &&
                   duplicateStore.snapshot.jobs[1].remoteJobID == "legacy-other-remote",
                   "岗位索引改变重复记录的首项匹配或没有更新批次内身份索引")
        let alternateAccount = UUID()
        duplicateFixture.jobs = (0..<200).map { index in
            var item = firstDuplicate
            item.id = "local-\(index % 23)"
            item.remoteJobID = "remote-\(index % 17)"
            item.accountID = index.isMultiple(of: 2) ? firstDuplicate.accountID : alternateAccount
            return item
        }
        let collisionPersistence = JSONStatePersistence(fileURL: root.appendingPathComponent("collisions.json"))
        try collisionPersistence.save(duplicateFixture)
        let collisionStore = AppStore(persistence: collisionPersistence)
        collisionStore.load()
        var expectedJobs = collisionStore.snapshot.jobs
        let collisionBatch = (0..<400).map { index in
            var item = firstDuplicate
            item.id = "local-\((index * 7) % 31)"
            let remote = "remote-\((index * 11) % 29)"
            item.remoteJobID = index.isMultiple(of: 13) ? nil : (index.isMultiple(of: 5) ? " \(remote) " : remote)
            item.accountID = index.isMultiple(of: 3) ? firstDuplicate.accountID : alternateAccount
            item.capturedAt = Date(timeIntervalSince1970: Double(2_100_000_000 + index))
            return item
        }
        for item in collisionBatch {
            let index = expectedJobs.firstIndex { existing in
                if existing.id == item.id { return true }
                guard existing.accountID == item.accountID,
                      let remote = item.remoteJobID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !remote.isEmpty else { return false }
                return existing.remoteJobID == remote
            }
            if let index { expectedJobs[index] = item } else { expectedJobs.append(item) }
        }
        collisionStore.upsertJobs(collisionBatch)
        let identity = { (item: JobListing) in
            "\(item.id)|\(item.accountID)|\(item.remoteJobID ?? "nil")|\(item.capturedAt.timeIntervalSince1970)"
        }
        try verify(collisionStore.snapshot.jobs.map(identity).sorted() == expectedJobs.map(identity).sorted(),
                   "岗位索引在重复标识、空路由、空白路由或跨账号混合批次中偏离原匹配行为")
    }

    private static func verifyMetricCardLayout(outputDirectory: URL) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let cases: [(CGFloat, Int)] = [(496, 2), (659, 2), (660, 4), (724, 4), (980, 4)]
        for (width, expectedColumns) in cases {
            let columns = MetricCard.columns(for: width)
            try verify(columns.count == expectedColumns, "统计卡片列数未遵守四列或两列布局")
            let grid = LazyVGrid(columns: columns, spacing: 12) {
                MetricCard(title: "推荐岗位", value: "12", detail: "共 12345 个岗位",
                           systemImage: "briefcase.fill", color: BossPilotTheme.accent)
                MetricCard(title: "未读消息", value: "9999", detail: "12345 个会话",
                           systemImage: "bubble.left.fill", color: BossPilotTheme.accent)
                MetricCard(title: "今日开聊", value: "150/150", detail: "剩余 0 次",
                           systemImage: "paperplane.fill", color: .orange)
                MetricCard(title: "今日交换", value: "99", detail: "附件简历",
                           systemImage: "arrow.left.arrow.right", color: .green)
            }
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: grid)
            renderer.scale = 1
            let image = try required(renderer.nsImage, "无法渲染统计卡片布局")
            let expectedHeight = expectedColumns == 4 ? MetricCard.height : 2 * MetricCard.height + 12
            try verify(abs(image.size.width - width) < 1 && abs(image.size.height - expectedHeight) < 1,
                       "统计卡片被挤出额外一行或尺寸溢出")
            let tiff = try required(image.tiffRepresentation, "无法读取卡片布局图像")
            let bitmap = try required(NSBitmapImageRep(data: tiff), "无法转换卡片布局图像")
            let png = try required(bitmap.representation(using: .png, properties: [:]), "无法导出卡片布局图像")
            try png.write(to: outputDirectory.appendingPathComponent("width-\(Int(width)).png"))
        }
        fputs("LAYOUT snapshots: \(outputDirectory.path)\n", stderr)
    }

    private static func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SelfCheckError.failed(message) }
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SelfCheckError.failed(message) }
        return value
    }
}
