import Combine
import Foundation

enum BossAccountSessionPhase: Equatable {
    case idle
    case restoring
    case loginRequired
    case authenticated
    case signingOut
    case deleting
    case removalFailed(String)
    case failed(String)

    var isAuthenticated: Bool {
        self == .authenticated
    }
}

enum BossCredentialReplacementEvent {
    case begin
    case finish
}

enum BossCredentialReplacementState: Equatable {
    case idle
    case replacing

    var isInProgress: Bool { self == .replacing }
    var allowsWarmupWebView: Bool { self == .idle }

    func applying(_ event: BossCredentialReplacementEvent) -> Self {
        switch event {
        case .begin: .replacing
        case .finish: .idle
        }
    }
}

enum BossAuthoritativeCredentialOutcome: Equatable {
    case applied
    case expired
    case failed
}

@MainActor
final class BossAccountSessionController: ObservableObject {
    @Published private(set) var phase: BossAccountSessionPhase = .idle
    @Published private(set) var automationReady = false
    @Published private(set) var profileBindingVerified = false
    @Published private(set) var credentialUpdatedAt: Date?
    @Published private(set) var credentialReplacementState: BossCredentialReplacementState = .idle

    let accountID: UUID
    let profileID: UUID
    let browser: BossBrowserController
    let qrLogin: BossQRCodeLoginController

    private let onAuthenticationInvalidated: (UUID) -> Void
    private let onIdentityRevisionChanged: (UUID) -> Void
    private let credentialVault: BossCredentialVault
    private var credentialRestoreAllowed: Bool
    private var cachedCredential: BossCredential?
    private var lastIdentityFingerprint: String?
    private var identityRevision: UInt64 = 0
    private var lifecycleRevision: UInt64 = 0
    private var isRemoved = false
    private var identityLossTask: Task<Void, Never>?
    private var webCookieObservationTask: Task<Void, Never>?
    private var webCookieObservationRevision: UInt64 = 0
    private var identityRevalidationPending = false
    private var needsObservationAfterCookieReplacement = false

    var isCredentialReplacementInProgress: Bool {
        credentialReplacementState.isInProgress
    }

    var shouldMountWarmupWebView: Bool {
        phase.isAuthenticated && !automationReady && credentialReplacementState.allowsWarmupWebView
    }

    init(
        accountID: UUID,
        profileID: UUID,
        allowsCredentialRestore: Bool,
        credentialVault: BossCredentialVault = .live,
        onAuthenticationInvalidated: @escaping (UUID) -> Void = { _ in },
        onIdentityRevisionChanged: @escaping (UUID) -> Void = { _ in }
    ) {
        self.accountID = accountID
        self.profileID = profileID
        credentialRestoreAllowed = allowsCredentialRestore
        self.credentialVault = credentialVault
        self.onAuthenticationInvalidated = onAuthenticationInvalidated
        self.onIdentityRevisionChanged = onIdentityRevisionChanged
        browser = BossBrowserController(profileID: profileID)
        qrLogin = BossQRCodeLoginController(profileID: profileID)
        qrLogin.onLoginSucceeded = { [weak self] credential in
            Task { @MainActor [weak self] in
                await self?.completeQRCodeLogin(credential)
            }
        }
    }

    func restoreIfNeeded() async {
        guard !isRemoved, phase == .idle || isFailure else { return }
        let revision = lifecycleRevision
        phase = .restoring
        if credentialRestoreAllowed {
            do {
                if let storedCredential = try credentialVault.load(profileID: profileID) {
                    await BossWebSessionService.importCookies(storedCredential.httpCookies, profileID: profileID)
                    guard isCurrent(revision) else { return }
                    applyAuthenticated(storedCredential)
                    return
                }
            } catch {
                guard isCurrent(revision) else { return }
                phase = .failed("恢复本地 BOSS 会话失败：\(error.localizedDescription)")
                return
            }
            let cookies = await BossWebSessionService.cookies(profileID: profileID)
            guard isCurrent(revision) else { return }
            let credential = BossCredential(cookies: cookies)
            if credential.hasIdentity {
                do {
                    try credentialVault.save(credential, profileID: profileID)
                } catch {
                    phase = .failed("保存本地 BOSS 会话失败：\(error.localizedDescription)")
                    return
                }
                applyAuthenticated(credential)
                return
            }
        }
        guard isCurrent(revision) else { return }
        phase = .loginRequired
        qrLogin.startIfNeeded()
    }

    func restartQRCodeLogin() {
        guard !isRemoved, phase == .loginRequired || isFailure else { return }
        credentialRestoreAllowed = false
        phase = .loginRequired
        qrLogin.restart()
    }

    func observeWebCookies(_ cookies: [HTTPCookie]) {
        guard !isRemoved, phase.isAuthenticated else { return }
        if isCredentialReplacementInProgress {
            needsObservationAfterCookieReplacement = true
            return
        }
        let observedCredential = BossCredential(cookies: cookies)
        if observedCredential.hasIdentity {
            if observedCredential.identityFingerprint != lastIdentityFingerprint {
                beginIdentityRevalidation(observedFingerprint: observedCredential.identityFingerprint)
            }
        } else if cachedCredential?.hasIdentity == true || lastIdentityFingerprint != nil {
            beginIdentityRevalidation(observedFingerprint: nil)
        }
        webCookieObservationTask?.cancel()
        webCookieObservationRevision &+= 1
        let observationRevision = webCookieObservationRevision
        let revision = lifecycleRevision
        webCookieObservationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.webCookieObservationRevision == observationRevision {
                    self.webCookieObservationTask = nil
                }
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard self.isCurrent(revision),
                      self.phase.isAuthenticated,
                      !self.isCredentialReplacementInProgress,
                      self.webCookieObservationRevision == observationRevision else { return }
                let currentCookies = await BossWebSessionService.cookies(profileID: self.profileID)
                guard self.isCurrent(revision),
                      self.phase.isAuthenticated,
                      !self.isCredentialReplacementInProgress,
                      self.webCookieObservationRevision == observationRevision else { return }
                self.applyObservedWebCookies(currentCookies)
            } catch is CancellationError {
                return
            } catch {
                if self.isCurrent(revision) { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    @discardableResult
    func markServerSessionExpired() async -> Bool {
        guard !isRemoved, phase.isAuthenticated else { return false }
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        identityLossTask?.cancel()
        cancelWebCookieObservation()
        qrLogin.stop()
        credentialRestoreAllowed = false
        cachedCredential = nil
        lastIdentityFingerprint = nil
        identityRevalidationPending = false
        invalidateIdentityRevision()
        onAuthenticationInvalidated(accountID)
        phase = .signingOut
        var cleanupError: Error?
        do {
            try credentialVault.remove(profileID: profileID)
        } catch {
            cleanupError = cleanupError ?? error
        }
        do {
            try await BossWebSessionService.clear(dataStore: BossWebSessionService.dataStore(for: profileID))
        } catch {
            cleanupError = cleanupError ?? error
        }
        guard !isRemoved, lifecycleRevision == revision, phase == .signingOut else { return false }
        automationReady = false
        credentialUpdatedAt = nil
        if let cleanupError {
            phase = .failed("登录已失效，但本地凭证未能完全清理：\(cleanupError.localizedDescription)")
            return false
        }
        phase = .loginRequired
        qrLogin.restart()
        return true
    }

    func beginSignOutBarrier() {
        guard !isRemoved, phase != .deleting, phase != .signingOut else { return }
        lifecycleRevision &+= 1
        identityLossTask?.cancel()
        cancelWebCookieObservation()
        qrLogin.stop()
        credentialRestoreAllowed = false
        cachedCredential = nil
        lastIdentityFingerprint = nil
        identityRevalidationPending = false
        invalidateIdentityRevision()
        onAuthenticationInvalidated(accountID)
        automationReady = false
        phase = .signingOut
    }

    func signOut() async throws {
        beginSignOutBarrier()
        guard !isRemoved, phase == .signingOut else { return }
        let revision = lifecycleRevision
        do {
            for _ in 0..<100 where isCredentialReplacementInProgress {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !isCredentialReplacementInProgress else { throw BossSessionError.sessionUpdateTimedOut }
            try credentialVault.remove(profileID: profileID)
            try await BossWebSessionService.clear(dataStore: BossWebSessionService.dataStore(for: profileID))
            guard !isRemoved, lifecycleRevision == revision, phase == .signingOut else { return }
            automationReady = false
            credentialUpdatedAt = nil
            phase = .loginRequired
            qrLogin.restart()
        } catch {
            if !isRemoved, lifecycleRevision == revision { phase = .failed(error.localizedDescription) }
            throw error
        }
    }

    func beginDeletionBarrier() {
        guard !isRemoved, phase != .deleting else { return }
        lifecycleRevision &+= 1
        identityLossTask?.cancel()
        cancelWebCookieObservation()
        automationReady = false
        credentialUpdatedAt = nil
        cachedCredential = nil
        lastIdentityFingerprint = nil
        identityRevalidationPending = false
        invalidateIdentityRevision()
        phase = .deleting
        credentialRestoreAllowed = false
        qrLogin.invalidate()
        BossWebSessionService.beginRetiring(profileID: profileID)
    }

    func restorePendingDeletionState() {
        beginDeletionBarrier()
        phase = .removalFailed("上次删除尚未完成；登录恢复和自动任务已保持关闭，请重新执行删除。")
    }

    func removeLocalData() async throws {
        guard !isRemoved else { return }
        if phase != .deleting { beginDeletionBarrier() }
        do {
            try credentialVault.remove(profileID: profileID)
            try await BossWebSessionService.clear(dataStore: BossWebSessionService.dataStore(for: profileID))
            automationReady = false
            credentialUpdatedAt = nil
        } catch {
            phase = .removalFailed(error.localizedDescription)
            throw error
        }
    }

    func finalizeRemoval() {
        lifecycleRevision &+= 1
        identityLossTask?.cancel()
        cancelWebCookieObservation()
        isRemoved = true
        automationReady = false
        credentialUpdatedAt = nil
        cachedCredential = nil
        lastIdentityFingerprint = nil
        identityRevalidationPending = false
        invalidateIdentityRevision()
        phase = .deleting
    }

    func reportRemovalFailure(_ error: Error) {
        guard !isRemoved else { return }
        phase = .removalFailed(error.localizedDescription)
    }

    func credential() throws -> BossCredential {
        guard !isRemoved, phase.isAuthenticated else { throw BossSessionError.loginRequired }
        guard let credential = cachedCredential, credential.hasIdentity else {
            throw BossSessionError.loginRequired
        }
        return credential
    }

    /// 用户完成本人验证后，从同一 WebKit Profile 刷新凭据；此操作本身不清除验证状态。
    @discardableResult
    func refreshCredentialFromWebKit() async -> Bool {
        guard !isRemoved, phase.isAuthenticated else { return false }
        let revision = lifecycleRevision
        let cookies = await BossWebSessionService.cookies(profileID: profileID)
        guard isCurrent(revision), phase.isAuthenticated else { return false }
        applyObservedWebCookies(cookies)
        return automationReady
    }

    func currentIdentityRevision(requiringProfileBinding: Bool = false) -> UInt64? {
        guard !isRemoved,
              phase.isAuthenticated,
              cachedCredential?.hasIdentity == true,
              !requiringProfileBinding || profileBindingVerified else {
            return nil
        }
        return identityRevision
    }

    func isCurrentIdentityRevision(_ expectedRevision: UInt64, requiringProfileBinding: Bool = false) -> Bool {
        currentIdentityRevision(requiringProfileBinding: requiringProfileBinding) == expectedRevision
    }

    func markProfileBindingVerified(identityRevision expectedRevision: UInt64) {
        guard isCurrentIdentityRevision(expectedRevision) else { return }
        profileBindingVerified = true
    }

    func markAutomationCredentialStale() async {
        guard !isRemoved, phase.isAuthenticated else { return }
        let revision = lifecycleRevision
        // 错误 37 由官方页面轮换动态令牌；保留原 Cookie，避免改变浏览器身份。
        guard isCurrent(revision), phase.isAuthenticated else { return }
        automationReady = false
        credentialUpdatedAt = nil
    }

    private func completeQRCodeLogin(_ credential: BossCredential) async {
        let revision = lifecycleRevision
        guard isCurrent(revision), phase == .loginRequired else { return }
        guard credential.hasIdentity else {
            phase = .failed(BossSessionError.loginRequired.localizedDescription)
            return
        }
        do {
            try credentialVault.save(credential, profileID: profileID)
        } catch {
            guard isCurrent(revision), phase == .loginRequired else { return }
            phase = .failed("保存本地 BOSS 会话失败：\(error.localizedDescription)")
            return
        }
        guard isCurrent(revision), phase == .loginRequired else { return }
        credentialRestoreAllowed = true
        applyAuthenticated(credential)
    }

    private func applyAuthenticated(_ credential: BossCredential, preserveProfileBinding: Bool = false) {
        guard !isRemoved else { return }
        switch phase {
        case .restoring, .loginRequired, .authenticated:
            break
        default:
            return
        }
        if !preserveProfileBinding {
            identityRevision &+= 1
            profileBindingVerified = false
            onIdentityRevisionChanged(accountID)
        }
        identityRevalidationPending = false
        lastIdentityFingerprint = credential.identityFingerprint
        automationReady = credential.isAutomationReady
        credentialUpdatedAt = credential.savedAt
        cachedCredential = credential
        credentialRestoreAllowed = true
        phase = .authenticated
        persistCredentialIfCurrent(credential, revision: lifecycleRevision)
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        !isRemoved && phase != .deleting && lifecycleRevision == revision
    }

    private func scheduleIdentityLossVerification() {
        guard phase.isAuthenticated, identityLossTask == nil else { return }
        let revision = lifecycleRevision
        identityLossTask = Task { [weak self] in
            guard let self else { return }
            defer { self.identityLossTask = nil }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isCurrent(revision) else { return }
                let first = await BossWebSessionService.cookies(profileID: self.profileID)
                if BossWebSessionService.isAuthenticated(cookies: first) {
                    self.applyObservedWebCookies(first)
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isCurrent(revision) else { return }
                let second = await BossWebSessionService.cookies(profileID: self.profileID)
                if BossWebSessionService.isAuthenticated(cookies: second) {
                    self.applyObservedWebCookies(second)
                    return
                }
                self.credentialRestoreAllowed = false
                self.cachedCredential = nil
                self.lastIdentityFingerprint = nil
                self.identityRevalidationPending = false
                self.invalidateIdentityRevision()
                self.onAuthenticationInvalidated(self.accountID)
                self.automationReady = false
                self.credentialUpdatedAt = nil
                self.phase = .loginRequired
                self.qrLogin.restart()
            } catch is CancellationError {
                return
            } catch {
                if self.isCurrent(revision) { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func applyAuthoritativeCredential(
        _ credential: BossCredential,
        identityRevision expectedRevision: UInt64
    ) async -> BossAuthoritativeCredentialOutcome {
        guard isCurrentIdentityRevision(expectedRevision) else { return .failed }
        identityLossTask?.cancel()
        identityLossTask = nil
        guard credential.hasIdentity else {
            _ = await markServerSessionExpired()
            return .expired
        }
        let revision = lifecycleRevision
        cancelWebCookieObservation()
        needsObservationAfterCookieReplacement = false
        credentialReplacementState = credentialReplacementState.applying(.begin)
        defer {
            credentialReplacementState = credentialReplacementState.applying(.finish)
        }
        await Task.yield()
        await BossWebSessionService.importCookies(credential.httpCookies, profileID: profileID)
        guard isCurrent(revision),
              phase.isAuthenticated,
              isCurrentIdentityRevision(expectedRevision) else { return .failed }
        applyAuthenticated(credential, preserveProfileBinding: true)
        if needsObservationAfterCookieReplacement {
            needsObservationAfterCookieReplacement = false
            let currentCookies = await BossWebSessionService.cookies(profileID: profileID)
            guard isCurrent(revision), phase.isAuthenticated else { return .failed }
            applyObservedWebCookies(currentCookies)
        }
        return .applied
    }

    private func applyObservedWebCookies(_ cookies: [HTTPCookie]) {
        let incoming = BossCredential(cookies: cookies)
        guard incoming.hasIdentity else {
            scheduleIdentityLossVerification()
            return
        }
        identityLossTask?.cancel()
        identityLossTask = nil
        let sameIdentityCookies = lastIdentityFingerprint == incoming.identityFingerprint
        applyAuthenticated(incoming, preserveProfileBinding: sameIdentityCookies)
    }

    private func persistCredentialIfCurrent(_ credential: BossCredential, revision: UInt64) {
        let fingerprint = credential.identityFingerprint
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrent(revision),
                  self.phase.isAuthenticated,
                  self.cachedCredential?.identityFingerprint == fingerprint else { return }
            do {
                try self.credentialVault.save(credential, profileID: self.profileID)
            } catch {
                guard self.isCurrent(revision), self.phase.isAuthenticated else { return }
                self.phase = .failed("保存本地 BOSS 会话失败：\(error.localizedDescription)")
            }
        }
    }

    private func cancelWebCookieObservation() {
        webCookieObservationRevision &+= 1
        webCookieObservationTask?.cancel()
        webCookieObservationTask = nil
    }

    private func invalidateIdentityRevision() {
        identityRevision &+= 1
        profileBindingVerified = false
        onIdentityRevisionChanged(accountID)
    }

    private func beginIdentityRevalidation(observedFingerprint: String?) {
        guard !identityRevalidationPending, phase.isAuthenticated else { return }
        identityRevalidationPending = true
        cachedCredential = nil
        automationReady = false
        credentialUpdatedAt = nil
        lastIdentityFingerprint = observedFingerprint
        invalidateIdentityRevision()
    }
}

@MainActor
final class BossSessionCoordinator: ObservableObject {
    private var sessions: [UUID: BossAccountSessionController] = [:]
    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]
    private var retiredAccountIDs: Set<UUID> = []
    private var authenticationInvalidationHandler: (UUID) -> Void = { _ in }
    private var identityRevisionHandler: (UUID) -> Void = { _ in }

    func bindAuthenticationInvalidation(_ handler: @escaping (UUID) -> Void) {
        authenticationInvalidationHandler = handler
    }

    func bindIdentityRevisionChange(_ handler: @escaping (UUID) -> Void) {
        identityRevisionHandler = handler
    }

    func session(for account: BossAccount) -> BossAccountSessionController {
        if let existing = sessions[account.id], existing.profileID == account.webProfileID {
            if account.status == .deleting,
               existing.phase != .deleting,
               !isRemovalFailure(existing.phase) {
                existing.restorePendingDeletionState()
            }
            return existing
        }
        let session = BossAccountSessionController(
            accountID: account.id,
            profileID: account.webProfileID,
            allowsCredentialRestore: account.loginStatus == .loggedIn,
            onAuthenticationInvalidated: { [weak self] accountID in
                self?.authenticationInvalidationHandler(accountID)
            },
            onIdentityRevisionChanged: { [weak self] accountID in
                self?.identityRevisionHandler(accountID)
            }
        )
        sessionSubscriptions[account.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if retiredAccountIDs.contains(account.id) {
            session.finalizeRemoval()
        } else if account.status == .deleting {
            session.restorePendingDeletionState()
        }
        sessions[account.id] = session
        return session
    }

    func existingSession(for accountID: UUID) -> BossAccountSessionController? {
        sessions[accountID]
    }

    func forget(accountID: UUID) {
        retiredAccountIDs.insert(accountID)
        sessions[accountID]?.finalizeRemoval()
        sessionSubscriptions[accountID]?.cancel()
        sessionSubscriptions[accountID] = nil
    }

    private func isRemovalFailure(_ phase: BossAccountSessionPhase) -> Bool {
        if case .removalFailed = phase { return true }
        return false
    }
}

enum BossSessionError: LocalizedError {
    case loginRequired
    case sessionUpdateTimedOut

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            "BOSS 登录态不存在或已失效，请重新扫码登录。"
        case .sessionUpdateTimedOut:
            "等待当前账号会话更新结束超时，本次清理已停止，请重试。"
        }
    }
}
