import AppKit
import Darwin
import SwiftUI
import UserNotifications

enum BossPilotSceneID {
    /// 递增场景版本以丢弃旧版异常窗口尺寸的恢复记录。
    static let main = "main-v2"
}

enum BossPilotProcessLockError: LocalizedError {
    case alreadyRunning
    case applicationSupportUnavailable
    case prepareDirectoryFailed(CInt)
    case openFailed(CInt)
    case descriptorProtectionFailed(CInt)
    case lockFailed(CInt)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "BossPilot 已在运行。"
        case .applicationSupportUnavailable:
            "无法定位应用支持目录，已停止启动以保护本地状态。"
        case .prepareDirectoryFailed(let code):
            "无法准备单实例锁目录（errno=\(code)），已停止启动以保护本地状态。"
        case .openFailed(let code):
            "无法打开单实例锁（errno=\(code)），已停止启动以保护本地状态。"
        case .descriptorProtectionFailed(let code):
            "无法保护单实例锁描述符（errno=\(code)），已停止启动以保护本地状态。"
        case .lockFailed(let code):
            "无法取得单实例锁（errno=\(code)），已停止启动以保护本地状态。"
        }
    }
}

final class BossPilotProcessLock {
    private var descriptor: CInt

    private init(descriptor: CInt) {
        self.descriptor = descriptor
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquireDefault() throws -> BossPilotProcessLock {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BossPilotProcessLockError.applicationSupportUnavailable
        }
        return try acquire(
            fileURL: applicationSupport
                .appendingPathComponent("BossPilot", isDirectory: true)
                .appendingPathComponent("instance.lock")
        )
    }

    static func acquire(fileURL: URL) throws -> BossPilotProcessLock {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw BossPilotProcessLockError.prepareDirectoryFailed(errno)
        }

        let fileDescriptor = open(
            fileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw BossPilotProcessLockError.openFailed(errno)
        }

        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0,
              fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let failureCode = errno
            close(fileDescriptor)
            throw BossPilotProcessLockError.descriptorProtectionFailed(failureCode)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failureCode = errno
            close(fileDescriptor)
            if failureCode == EWOULDBLOCK || failureCode == EAGAIN {
                throw BossPilotProcessLockError.alreadyRunning
            }
            throw BossPilotProcessLockError.lockFailed(failureCode)
        }
        return BossPilotProcessLock(descriptor: fileDescriptor)
    }

    var closesOnExec: Bool {
        guard descriptor >= 0 else { return false }
        return fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?
    private weak var store: AppStore?
    private weak var automation: BossAutomationController?
    private var performsLiveRuntimeWork = true
    private var terminationTask: Task<Void, Never>?

    func configure(
        store: AppStore,
        automation: BossAutomationController,
        performsLiveRuntimeWork: Bool
    ) {
        self.store = store
        self.automation = automation
        self.performsLiveRuntimeWork = performsLiveRuntimeWork
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 禁用自动标签页，确保 BOSS 官方页面作为独立窗口显示。
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openMainWindow else { return true }
        // 菜单栏常驻时，关闭主窗口不会终止应用。
        openMainWindow()
        return false
    }

    func showSystemSettings() {
        openMainWindow?()
        openSettings?()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard performsLiveRuntimeWork || store?.hasUnsavedRequirementsChanges == true || store?.isSavingRequirements == true else {
            store?.flush()
            return .terminateNow
        }
        guard let store, let automation else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [weak self] in
            guard await UnsavedRequirementsGuard.confirm(using: store) else {
                sender.reply(toApplicationShouldTerminate: false)
                self?.terminationTask = nil
                return
            }
            if self?.performsLiveRuntimeWork == true {
                await automation.prepareForTermination(using: store)
            } else {
                store.flush()
            }
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flush()
    }
}

@main
struct BossPilotApp: App {
    private let processLock: BossPilotProcessLock
    private let launchMode: BossPilotLaunchMode
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore
    @StateObject private var codex: CodexController
    @StateObject private var bossSessions: BossSessionCoordinator
    @StateObject private var bossAutomation: BossAutomationController

    init() {
        let processInfo = ProcessInfo.processInfo
        let launchArguments = processInfo.arguments
        let resolvedLaunchMode = BossPilotLaunchMode.resolve(
            arguments: launchArguments,
            environment: processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: processInfo.processIdentifier
        )
        launchMode = resolvedLaunchMode
        if launchArguments.contains("--codex-smoke") {
            guard resolvedLaunchMode.performsLiveRuntimeWork else {
                fputs("BOSSPILOT UI PREVIEW BLOCKED: Codex smoke is unavailable in preview mode.\n", stderr)
                exit(EXIT_FAILURE)
            }
            CodexSmoke.runAndExit()
        }
        if launchArguments.contains("--self-check") {
            do {
                let checks = try SelfCheck.run()
                checks.forEach { print("PASS \($0)") }
                print("SELF-CHECK PASSED: \(checks.count)")
                exit(EXIT_SUCCESS)
            } catch {
                fputs("SELF-CHECK FAILED: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        do {
            if let previewRuntime = resolvedLaunchMode.previewRuntime {
                processLock = try BossPilotProcessLock.acquire(fileURL: previewRuntime.processLockURL)
            } else {
                processLock = try BossPilotProcessLock.acquireDefault()
            }
        } catch BossPilotProcessLockError.alreadyRunning {
            if resolvedLaunchMode.performsLiveRuntimeWork,
               let bundleIdentifier = Bundle.main.bundleIdentifier,
               let existing = NSRunningApplication.runningApplications(
                   withBundleIdentifier: bundleIdentifier
               ).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                if let bundleURL = existing.bundleURL {
                    NSWorkspace.shared.open(bundleURL)
                }
                _ = existing.activate(options: [.activateAllWindows])
            }
            exit(EXIT_SUCCESS)
        } catch {
            fputs("BOSSPILOT STARTUP BLOCKED: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        if launchArguments.contains("--boss-read-smoke") {
            guard resolvedLaunchMode.performsLiveRuntimeWork else {
                fputs("BOSSPILOT UI PREVIEW BLOCKED: BOSS smoke is unavailable in preview mode.\n", stderr)
                exit(EXIT_FAILURE)
            }
            BossReadSmoke.runAndExit()
        }
        if launchArguments.contains("--boss-greeting-delivery") {
            guard resolvedLaunchMode.performsLiveRuntimeWork else {
                fputs("BOSSPILOT UI PREVIEW BLOCKED: greeting delivery is unavailable in preview mode.\n", stderr)
                exit(EXIT_FAILURE)
            }
            BossGreetingDeliverySmoke.runAndExit()
        }
        if launchArguments.contains("--boss-greeting-confirmation") {
            guard resolvedLaunchMode.performsLiveRuntimeWork else {
                fputs("BOSSPILOT UI PREVIEW BLOCKED: greeting confirmation is unavailable in preview mode.\n", stderr)
                exit(EXIT_FAILURE)
            }
            BossGreetingConfirmationSmoke.runAndExit(resetWhenAuthoritativelyAbsent: false)
        }
        if launchArguments.contains("--boss-greeting-reset-confirmed-absent") {
            guard resolvedLaunchMode.performsLiveRuntimeWork else {
                fputs("BOSSPILOT UI PREVIEW BLOCKED: greeting reset is unavailable in preview mode.\n", stderr)
                exit(EXIT_FAILURE)
            }
            BossGreetingConfirmationSmoke.runAndExit(resetWhenAuthoritativelyAbsent: true)
        }

        let appStore: AppStore
        if let previewRuntime = resolvedLaunchMode.previewRuntime {
            appStore = AppStore(persistence: JSONStatePersistence(fileURL: previewRuntime.stateURL))
        } else {
            appStore = AppStore()
        }
        appStore.load()
        if resolvedLaunchMode.performsLiveRuntimeWork {
            let notifications = UNUserNotificationCenter.current()
            notifications.removeAllPendingNotificationRequests()
            notifications.removeAllDeliveredNotifications()
        }
        _store = StateObject(wrappedValue: appStore)
        let codexHome = resolvedLaunchMode.previewRuntime?.stateURL.deletingLastPathComponent().appendingPathComponent("Codex")
        _codex = StateObject(wrappedValue: codexHome.map {
            CodexController(service: CodexCLIService(codexHome: $0))
        } ?? CodexController())
        _bossSessions = StateObject(wrappedValue: BossSessionCoordinator())
        let automation = BossAutomationController()
        _bossAutomation = StateObject(wrappedValue: automation)
        appDelegate.configure(
            store: appStore,
            automation: automation,
            performsLiveRuntimeWork: resolvedLaunchMode.performsLiveRuntimeWork
        )
    }

    var body: some Scene {
        Window("BossPilot", id: BossPilotSceneID.main) {
            ContentView(
                launchMode: launchMode,
                registerMainWindowOpener: { appDelegate.openMainWindow = $0 },
                registerSettingsOpener: { appDelegate.openSettings = $0 }
            )
                .environmentObject(store)
                .environmentObject(codex)
                .environmentObject(bossSessions)
                .environmentObject(bossAutomation)
                .frame(
                    minWidth: 1_080,
                    maxWidth: .infinity,
                    minHeight: 700,
                    maxHeight: .infinity
                )
        }
        .defaultSize(width: 1_260, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("系统设置…") { appDelegate.showSystemSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("求职") {
                Button("立即保存本地数据") {
                    store.flush()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }

        WindowGroup("BOSS 官方页面", for: BossOfficialPageRequest.self) { $request in
            if launchMode.performsLiveRuntimeWork, let request {
                BossOfficialBrowserWindow(request: request)
                    .environmentObject(store)
                    .environmentObject(bossSessions)
                    .environmentObject(bossAutomation)
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 1_440, height: 900)

        MenuBarExtra("BossPilot", systemImage: "briefcase.fill") {
            if launchMode.performsLiveRuntimeWork {
                MenuBarContentView()
                    .environmentObject(store)
            } else {
                Text("UI Preview")
            }
        }
    }
}

private enum BossGreetingDeliverySmokeError: LocalizedError {
    case workerMustRemainStopped
    case targetIsAmbiguous
    case targetIsIncomplete
    case authorizationChanged
    case manualVerificationPending

    var errorDescription: String? {
        switch self {
        case .workerMustRemainStopped:
            "One-shot greeting delivery requires the automatic worker to remain stopped."
        case .targetIsAmbiguous:
            "Expected exactly one unconfirmed automatic greeting target."
        case .targetIsIncomplete:
            "The unconfirmed greeting target is missing its account, job, route, or text."
        case .authorizationChanged:
            "The account, target, or configured greeting changed before the write commit."
        case .manualVerificationPending:
            "The target BOSS account is waiting for the user to complete manual verification."
        }
    }
}

private struct BossGreetingDeliveryTarget {
    let account: BossAccount
    let job: JobListing
    let remoteIdentityID: String
}

@MainActor
private func restoreGreetingWebSession(profileID: UUID) async throws -> BossCredential {
    guard let credential = try BossCredentialVault.live.load(profileID: profileID),
          credential.hasIdentity else {
        throw BossResumeExchangeError.unauthenticated
    }
    await BossWebSessionService.importCookies(
        credential.connectorCookies,
        profileID: profileID
    )
    guard await BossWebSessionService.isAuthenticated(profileID: profileID) else {
        throw BossResumeExchangeError.unauthenticated
    }
    return credential
}

private enum BossGreetingDeliverySmoke {
    @MainActor
    static func runAndExit() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                let store = AppStore()
                store.load()
                guard !store.snapshot.automation.workerEnabled else {
                    throw BossGreetingDeliverySmokeError.workerMustRemainStopped
                }
                let greeting = store.snapshot.preferences.greetingTemplate
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !greeting.isEmpty else {
                    throw BossGreetingDeliverySmokeError.targetIsIncomplete
                }

                guard store.snapshot.automation.allowsExternalActions,
                      store.snapshot.automation.automaticallySendGreetings else {
                    throw BossGreetingDeliverySmokeError.authorizationChanged
                }
                let candidates: [BossGreetingDeliveryTarget] = store.snapshot.jobs.compactMap { job in
                    guard job.stage == .recommended,
                          let securityID = job.securityID?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ), !securityID.isEmpty,
                          let remoteJobID = job.remoteJobID?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ), !remoteJobID.isEmpty,
                          let listID = job.listID?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ), !listID.isEmpty,
                          !store.hasAutomaticGreetingAttempt(
                            accountID: job.accountID,
                            remoteJobID: remoteJobID
                          ),
                          let account = store.snapshot.accounts.first(where: {
                            $0.id == job.accountID &&
                                BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: $0)
                          }),
                          let remoteIdentityID = account.remoteProfile?.remoteID.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ), !remoteIdentityID.isEmpty else {
                        return nil
                    }
                    return BossGreetingDeliveryTarget(
                        account: account,
                        job: job,
                        remoteIdentityID: remoteIdentityID
                    )
                }.sorted { lhs, rhs in
                    let lhsScore = lhs.job.assessment?.score ?? 0
                    let rhsScore = rhs.job.assessment?.score ?? 0
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                    if lhs.job.capturedAt != rhs.job.capturedAt {
                        return lhs.job.capturedAt > rhs.job.capturedAt
                    }
                    return lhs.job.id < rhs.job.id
                }
                guard let target = candidates.first,
                      let securityID = target.job.securityID?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ), !securityID.isEmpty,
                      let remoteJobID = target.job.remoteJobID?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ), !remoteJobID.isEmpty,
                      let listID = target.job.listID?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ), !listID.isEmpty else {
                    throw BossGreetingDeliverySmokeError.targetIsIncomplete
                }
                guard BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: target.account) else {
                    throw BossGreetingDeliverySmokeError.manualVerificationPending
                }

                var credential = try await restoreGreetingWebSession(
                    profileID: target.account.webProfileID
                )
                guard credential.isAutomationReady else {
                    throw BossAutomationError.incompleteWebCredential
                }
                try store.prepareAutomaticGreeting(jobID: target.job.id)
                let api = BossAPIService()
                let requestToken = api.requestToken(accountID: target.account.id)
                let greetResult = try await api.greet(
                    accountID: target.account.id,
                    profileID: target.account.webProfileID,
                    credential: credential,
                    requestToken: requestToken,
                    securityID: securityID,
                    jobID: remoteJobID,
                    listID: listID
                )
                credential = greetResult.refreshedCredential
                try BossCredentialVault.live.save(
                    credential,
                    profileID: target.account.webProfileID
                )
                await BossWebSessionService.importCookies(
                    credential.connectorCookies,
                    profileID: target.account.webProfileID
                )
                let receipt = try await BossResumeExchangeService.shared.sendGreetingAndConfirm(
                    profileID: target.account.webProfileID,
                    expectedSecurityID: securityID,
                    expectedJobID: remoteJobID,
                    text: greeting,
                    commitIsStillAuthorized: {
                        guard !store.snapshot.automation.workerEnabled,
                              store.snapshot.automation.automaticallySendGreetings,
                              store.snapshot.preferences.greetingTemplate
                                .trimmingCharacters(in: .whitespacesAndNewlines) == greeting,
                              store.snapshot.accounts.contains(where: {
                                  $0.id == target.account.id &&
                                      BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: $0) &&
                                      $0.remoteProfile?.remoteID == target.remoteIdentityID
                              }),
                              store.snapshot.jobs.contains(where: {
                                  $0.id == target.job.id &&
                                      $0.accountID == target.account.id &&
                                      $0.stage == .greetingDrafted &&
                                      $0.remoteJobID == remoteJobID &&
                                      $0.securityID == target.job.securityID
                              }) else {
                            return false
                        }
                        return true
                    },
                    markWriteStarted: {
                        try store.markAutomaticGreetingWriteStarted(jobID: target.job.id)
                    }
                )
                guard !store.snapshot.automation.workerEnabled else {
                    throw BossGreetingDeliverySmokeError.authorizationChanged
                }
                store.recordAutomaticGreeting(
                    jobID: target.job.id,
                    confirmedMessageID: receipt.messageID,
                    deliveredAt: receipt.deliveredAt
                )
                store.flush()
                let payload: [String: Any] = [
                    "account": target.account.selectionLabel(in: store.snapshot.accounts),
                    "job": target.job.title,
                    "recruiter": receipt.recruiterName,
                    "messageID": receipt.messageID,
                    "deliveredAt": ISO8601DateFormatter().string(from: receipt.deliveredAt),
                    "workerEnabled": store.snapshot.automation.workerEnabled
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                fflush(stdout)
                exit(EXIT_SUCCESS)
                } catch {
                    fputs("BOSS GREETING DELIVERY FAILED: \(error.localizedDescription)\n", stderr)
                    fflush(stderr)
                    exit(EXIT_FAILURE)
                }
            }
        }
        NSApp.run()
        exit(EXIT_FAILURE)
    }
}

private enum BossGreetingConfirmationSmoke {
    @MainActor
    static func runAndExit(resetWhenAuthoritativelyAbsent: Bool) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.async {
            Task { @MainActor in
                let store = AppStore()
                var targetJobID: String?
                do {
                    store.load()
                    guard !store.snapshot.automation.workerEnabled else {
                        throw BossGreetingDeliverySmokeError.workerMustRemainStopped
                    }
                    let greeting = store.snapshot.preferences.greetingTemplate
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let candidates: [(AutomaticGreetingAttempt, BossAccount, JobListing)] = store.snapshot
                        .automaticGreetingAttempts.compactMap { attempt in
                            guard let writeStartedAt = attempt.deliveryWriteStartedAt,
                                  attempt.confirmedMessageID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                                  let account = store.snapshot.accounts.first(where: {
                                      BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: $0) &&
                                          $0.remoteProfile?.remoteID == attempt.remoteIdentityID
                                  }),
                                  let job = store.snapshot.jobs.first(where: {
                                      $0.accountID == account.id && $0.remoteJobID == attempt.remoteJobID
                                  }) else { return nil }
                            _ = writeStartedAt
                            return (attempt, account, job)
                        }
                        .sorted {
                            ($0.0.deliveryWriteStartedAt ?? .distantPast) >
                                ($1.0.deliveryWriteStartedAt ?? .distantPast)
                        }
                    guard let target = candidates.first,
                          let writeStartedAt = target.0.deliveryWriteStartedAt,
                          let securityID = target.2.securityID?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !securityID.isEmpty, !greeting.isEmpty else {
                        throw BossGreetingDeliverySmokeError.targetIsAmbiguous
                    }
                    guard BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: target.1) else {
                        throw BossGreetingDeliverySmokeError.manualVerificationPending
                    }
                    targetJobID = target.2.id
                    _ = try await restoreGreetingWebSession(profileID: target.1.webProfileID)
                    let receipt = try await BossResumeExchangeService.shared.confirmGreetingDelivery(
                        profileID: target.1.webProfileID,
                        expectedSecurityID: securityID,
                        expectedJobID: target.0.remoteJobID,
                        text: greeting,
                        writeStartedAt: writeStartedAt
                    )
                    store.recordAutomaticGreeting(
                        jobID: target.2.id,
                        confirmedMessageID: receipt.messageID,
                        deliveredAt: receipt.deliveredAt
                    )
                    store.flush()
                    let payload: [String: Any] = [
                        "account": target.1.selectionLabel(in: store.snapshot.accounts),
                        "job": target.2.title,
                        "recruiter": receipt.recruiterName,
                        "messageID": receipt.messageID,
                        "deliveredAt": ISO8601DateFormatter().string(from: receipt.deliveredAt),
                        "workerEnabled": store.snapshot.automation.workerEnabled
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch BossResumeExchangeError.greetingDeliveryUnconfirmed
                    where resetWhenAuthoritativelyAbsent {
                    do {
                        guard let targetJobID else {
                            throw BossGreetingDeliverySmokeError.targetIsAmbiguous
                        }
                        try store.reopenAutomaticGreetingAfterAuthoritativeAbsence(jobID: targetJobID)
                        print("BOSS GREETING AUTHORITATIVE ABSENCE CONFIRMED; SINGLE RETRY ENABLED")
                        fflush(stdout)
                        exit(EXIT_SUCCESS)
                    } catch {
                        fputs("BOSS GREETING RESET FAILED: \(error.localizedDescription)\n", stderr)
                        fflush(stderr)
                        exit(EXIT_FAILURE)
                    }
                } catch {
                    fputs("BOSS GREETING CONFIRMATION FAILED: \(error.localizedDescription)\n", stderr)
                    fflush(stderr)
                    exit(EXIT_FAILURE)
                }
            }
        }
        NSApp.run()
        exit(EXIT_FAILURE)
    }
}

private enum BossReadSmoke {
    static func runAndExit() -> Never {
        Task { @MainActor in
            do {
                let store = AppStore()
                store.load()
                guard let account = store.snapshot.accounts.first(where: {
                    BossSmokeCommandSafetyPolicy.permitsConnectorAccess(for: $0)
                }) else {
                    if store.snapshot.accounts.contains(where: {
                        $0.status == .active && $0.manualVerificationChallenge != nil
                    }) {
                        throw BossGreetingDeliverySmokeError.manualVerificationPending
                    }
                    throw BossAutomationError.automationCredentialRequired
                }
                guard store.snapshot.automation.allowsConnectorReads else {
                    throw BossAutomationError.connectorReadsDisabled
                }
                guard let credential = try BossCredentialVault.live.load(profileID: account.webProfileID),
                      credential.hasIdentity else {
                    throw BossAutomationError.automationCredentialRequired
                }
                let fallbackPlan = JobSearchPlanningPolicy.fallbackSearchPlan(
                    resume: store.snapshot.resume,
                    requirementText: store.snapshot.preferences.requirementText
                )
                let nonblank: (String?) -> String? = { value in
                    guard let value else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                let query = nonblank(store.snapshot.preferences.plannedSearchQueries.first)
                    ?? nonblank(fallbackPlan.queries.first)
                let city = nonblank(store.snapshot.preferences.plannedCities.first)
                    ?? nonblank(fallbackPlan.cities.first)
                guard let query, let city else {
                    throw BossAutomationError.searchCriteriaRequired
                }
                guard let cityCode = BossCityResolver.code(for: city) else {
                    throw BossAutomationError.unsupportedCity(city)
                }
                // 无界面诊断不启动 WebKit；WebKit 需要完整的 AppKit 生命周期。
                let api = BossAPIService(allowsWebFallback: false)
                let token = api.requestToken(accountID: account.id)
                let jobs = try await api.searchJobs(
                    accountID: account.id,
                    profileID: account.webProfileID,
                    credential: credential,
                    requestToken: token,
                    query: query,
                    cityCode: cityCode
                )
                let friends = try await api.friendSummaries(
                    accountID: account.id,
                    profileID: account.webProfileID,
                    credential: jobs.refreshedCredential,
                    requestToken: token
                )
                let payload: [String: Any] = [
                    "account": account.selectionLabel(in: store.snapshot.accounts),
                    "query": query,
                    "city": city,
                    "jobCount": jobs.value.count,
                    "conversationCount": friends.value.count
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(EXIT_SUCCESS)
            } catch {
                fputs("BOSS READ SMOKE FAILED: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}

private enum CodexSmoke {
    static func runAndExit() -> Never {
        Task.detached {
            do {
                var preferences = JobPreferences()
                preferences.requirementText = "寻找 Java 后端开发岗位，必须使用 Spring Boot，不考虑外包。"
                preferences.plannedSearchQueries = ["Java 开发工程师"]
                let resume = ResumeProfile(
                    name: "Codex 冒烟简历",
                    text: "5 年 Java 开发经验，熟悉 Spring Boot、MySQL 和微服务。",
                    skills: ["Java", "Spring Boot", "MySQL"],
                    targetRoles: ["Java 开发工程师"],
                    yearsOfExperience: 5,
                    profileSummary: "5 年 Java 后端开发经验，技术主线为 Spring Boot、MySQL 与微服务，适合中高级后端开发岗位。",
                    suggestedSearchQueries: ["Java 开发工程师"],
                    profileGeneratedAt: Date(),
                    profileProvider: "测试"
                )
                let job = JobListing(
                    id: "codex-smoke-job",
                    accountID: UUID(),
                    title: "Java 开发工程师",
                    company: "结构化输出测试公司",
                    location: "上海",
                    salary: "20-30K",
                    experience: "3-5年",
                    education: "本科",
                    description: "负责基于 Spring Boot 和 MySQL 的微服务设计、开发、测试与上线。"
                )
                let service = CodexCLIService()
                let configuredPath = ProcessInfo.processInfo.environment["BOSSPILOT_CODEX_PATH"] ?? ""
                let assessment = try await service.assess(
                    job: job,
                    resume: resume,
                    preferences: preferences,
                    configuredPath: configuredPath,
                    model: "",
                    reasoningEffort: "medium",
                    timeoutSeconds: 120
                )
                guard assessment.confidence != .high, assessment.recommendation != "推荐" else {
                    throw CodexCLIError.invalidOutput("短 JD 未执行确定性降级")
                }
                print("CODEX-SMOKE PASSED: score=\(assessment.score) recommendation=\(assessment.recommendation) confidence=\(assessment.confidence.rawValue)")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("CODEX-SMOKE FAILED: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
