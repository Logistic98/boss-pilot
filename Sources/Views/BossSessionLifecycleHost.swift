import SwiftUI

/// 账号会话独立于当前页面存活，避免切页中断扫码、预热和资料同步。
struct BossSessionLifecycleHost: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossSessions: BossSessionCoordinator

    var body: some View {
        ZStack {
            ForEach(store.snapshot.accounts) { account in
                BossSessionLifecycleAgent(
                    account: account,
                    session: bossSessions.session(for: account)
                )
                .id(account.id)
            }
        }
        .frame(width: 1, height: 1)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BossSessionLifecycleAgent: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossAutomation: BossAutomationController
    let account: BossAccount
    @ObservedObject var session: BossAccountSessionController
    @StateObject private var warmupBrowser: BossBrowserController
    @State private var profileSyncRequested = false
    @State private var profileSyncRetryCount = 0
    @State private var waitingForRunningOperation = false
    @State private var warmupRetryCount = 0

    init(account: BossAccount, session: BossAccountSessionController) {
        self.account = account
        self.session = session
        _warmupBrowser = StateObject(wrappedValue: BossBrowserController(profileID: session.profileID))
    }

    var body: some View {
        Group {
            if session.shouldMountWarmupWebView, allowsAutomaticWork {
                BossWebView(
                    controller: warmupBrowser,
                    initialURL: OfficialBossLinkService.jobs,
                    isVisuallyHidden: true,
                    onCookiesChanged: session.observeWebCookies
                )
            } else {
                Color.clear
            }
        }
        .task {
            await session.restoreIfNeeded()
            reconcileSessionState()
        }
        .onChange(of: session.phase) { _, _ in
            reconcileSessionState()
        }
        .onChange(of: session.automationReady) { _, _ in
            reconcileSessionState()
        }
        .onChange(of: session.profileBindingVerified) { _, verified in
            if !verified { profileSyncRequested = false }
            reconcileSessionState()
        }
        .onChange(of: store.snapshot.automation.mode) { _, _ in
            reconcileSessionState()
        }
        .onChange(of: bossAutomation.runningAccountIDs.contains(account.id)) { _, running in
            if !running, waitingForRunningOperation, !session.profileBindingVerified {
                waitingForRunningOperation = false
                profileSyncRequested = false
                synchronizeProfileIfNeeded()
            }
        }
        .onChange(of: warmupBrowser.errorMessage) { _, message in
            guard message != nil,
                  allowsAutomaticWork,
                  session.phase.isAuthenticated,
                  !session.automationReady,
                  warmupRetryCount < 2 else { return }
            warmupRetryCount += 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(warmupRetryCount) * 1_000_000_000)
                guard allowsAutomaticWork,
                      session.phase.isAuthenticated,
                      !session.automationReady else { return }
                warmupBrowser.reload()
            }
        }
        .onChange(of: warmupBrowser.currentURL) { _, url in
            bossAutomation.registerManualVerificationPage(
                account: account,
                url: url,
                store: store
            )
        }
    }

    private func reconcileSessionState() {
        if session.phase.isAuthenticated {
            store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: true)
            if !session.automationReady {
                profileSyncRequested = false
            }
            synchronizeProfileIfNeeded()
        } else if session.phase == .loginRequired {
            store.synchronizeBossLoginStatus(accountID: account.id, loggedIn: false)
            profileSyncRequested = false
        }
    }

    private func synchronizeProfileIfNeeded() {
        guard allowsAutomaticWork,
              session.automationReady,
              store.snapshot.automation.allowsConnectorReads,
              !profileSyncRequested else { return }
        if bossAutomation.runningAccountIDs.contains(account.id) {
            waitingForRunningOperation = true
            return
        }
        waitingForRunningOperation = false
        if session.profileBindingVerified,
           let syncedAt = store.snapshot.accounts.first(where: { $0.id == account.id })?.remoteProfile?.syncedAt,
           Date().timeIntervalSince(syncedAt) < 6 * 60 * 60 {
            return
        }
        profileSyncRequested = true
        Task {
            let outcome = await bossAutomation.synchronizeProfile(
                account: account,
                session: session,
                store: store
            )
            if outcome == .performed {
                profileSyncRetryCount = 0
                return
            }
            profileSyncRequested = false
            guard allowsAutomaticWork,
                  session.phase.isAuthenticated,
                  session.automationReady,
                  store.snapshot.automation.allowsConnectorReads,
                  profileSyncRetryCount < 2 else { return }
            profileSyncRetryCount += 1
            try? await Task.sleep(nanoseconds: UInt64(profileSyncRetryCount) * 1_000_000_000)
            synchronizeProfileIfNeeded()
        }
    }

    private var allowsAutomaticWork: Bool {
        guard let currentAccount = store.snapshot.accounts.first(where: { $0.id == account.id }) else {
            return false
        }
        return BossManualVerificationGate.allowsAutomaticWork(for: currentAccount)
    }
}
