@preconcurrency import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import WebKit

enum BossQRCodeLoginStage: Equatable {
    case idle
    case preparing
    case waitingForScan
    case waitingForConfirmation
    case establishingSession
    case loggedIn
    case expired
    case failed(String)

    var title: String {
        switch self {
        case .idle: "准备扫码登录"
        case .preparing: "正在生成二维码"
        case .waitingForScan: "等待扫码"
        case .waitingForConfirmation: "已扫码，请在手机上确认"
        case .establishingSession: "已确认，正在建立登录会话"
        case .loggedIn: "登录成功"
        case .expired: "二维码已过期"
        case .failed: "登录失败"
        }
    }

    var activeStep: Int {
        switch self {
        case .idle, .preparing, .waitingForScan, .expired, .failed: 1
        case .waitingForConfirmation: 2
        case .establishingSession, .loggedIn: 3
        }
    }
}

enum BossQRCodeScanListenerState: Equatable {
    case idle
    case armed
    case completed
    case failed
}

enum BossQRCodeScanDisplayPolicy {
    static func permitsDisplay(
        generation: UInt64,
        currentGeneration: UInt64,
        listenerGeneration: UInt64?,
        state: BossQRCodeScanListenerState,
        isInvalidated: Bool
    ) -> Bool {
        guard !isInvalidated,
              generation == currentGeneration,
              listenerGeneration == generation else { return false }
        return state == .armed || state == .completed
    }
}

@MainActor
final class BossQRCodeLoginController: ObservableObject {
    @Published private(set) var stage: BossQRCodeLoginStage = .idle
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var expiresAt: Date?

    private static let baseURL = URL(string: "https://www.zhipin.com")!
    private static let qrLifetime: TimeInterval = 240
    private static let identityCookieNames: Set<String> = ["wt2", "zp_at"]

    private let profileID: UUID
    private var loginTask: Task<Void, Never>?
    private var urlSession: URLSession?
    private var cookieStorage: HTTPCookieStorage?
    private var loginGeneration: UInt64 = 0
    private var scanListenerGeneration: UInt64?
    private var scanListenerState: BossQRCodeScanListenerState = .idle
    private var isInvalidated = false
    var onLoginSucceeded: ((BossCredential) -> Void)?

    init(profileID: UUID) {
        self.profileID = profileID
    }

    deinit {
        loginTask?.cancel()
        urlSession?.invalidateAndCancel()
    }

    func startIfNeeded() {
        guard !isInvalidated, stage == .idle else { return }
        restart()
    }

    func restart() {
        guard !isInvalidated else { return }
        stop()
        loginGeneration &+= 1
        let generation = loginGeneration
        stage = .preparing
        qrImage = nil
        expiresAt = nil
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await runLoginFlow(generation: generation)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                if loginGeneration == generation, !isInvalidated {
                    stage = .failed(error.localizedDescription)
                    qrImage = nil
                }
            }
        }
    }

    func stop() {
        loginGeneration &+= 1
        loginTask?.cancel()
        loginTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        cookieStorage = nil
        scanListenerGeneration = nil
        scanListenerState = .idle
    }

    func invalidate() {
        isInvalidated = true
        onLoginSucceeded = nil
        stop()
        qrImage = nil
        expiresAt = nil
    }

    private func runLoginFlow(generation: UInt64) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 45
        guard let cookieStorage = configuration.httpCookieStorage else {
            throw LoginError.invalidResponse("无法创建隔离的登录会话。")
        }
        self.cookieStorage = cookieStorage
        let session = URLSession(configuration: configuration)
        urlSession = session

        let qrID = try await requestQRCodeID(using: session)
        try validateGeneration(generation)
        let generatedQRCode = try makeQRCode(from: qrID)
        expiresAt = Date().addingTimeInterval(Self.qrLifetime)
        stage = .waitingForScan

        // 先启动上游长轮询，等待三秒后显示二维码，避免扫码早于监听就绪。
        async let firstScanResult = waitForScan(qrID: qrID, using: session, generation: generation)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try validateGeneration(generation)
        guard BossQRCodeScanDisplayPolicy.permitsDisplay(
            generation: generation,
            currentGeneration: loginGeneration,
            listenerGeneration: scanListenerGeneration,
            state: scanListenerState,
            isInvalidated: isInvalidated
        ) else {
            throw LoginError.invalidResponse("扫码监听未成功建立，已拒绝显示无监听的二维码。")
        }
        qrImage = generatedQRCode
        var pendingFirstScan: Bool? = try await firstScanResult

        while !Task.isCancelled, loginGeneration == generation, !isInvalidated {
            guard let expiresAt, Date() < expiresAt else {
                stage = .expired
                return
            }

            let scanned: Bool
            if let first = pendingFirstScan {
                scanned = first
                pendingFirstScan = nil
            } else {
                scanned = try await waitForScan(qrID: qrID, using: session, generation: generation)
            }
            try validateGeneration(generation)
            guard scanned else { continue }
            stage = .waitingForConfirmation

            let confirmed = try await waitForConfirmation(qrID: qrID, using: session)
            try validateGeneration(generation)
            guard confirmed else { continue }
            stage = .establishingSession

            try await dispatchLogin(qrID: qrID, using: session)
            try validateGeneration(generation)
            let cookies = cookieStorage.cookies ?? []
            guard Set(cookies.map(\.name)).isSuperset(of: Self.identityCookieNames) else {
                throw LoginError.invalidResponse("手机已确认，但 BOSS 未返回完整登录会话，请刷新二维码重试。")
            }
            let credential = BossCredential(cookies: cookies)
            await BossWebSessionService.importCookies(credential.httpCookies, profileID: profileID)
            try validateGeneration(generation)
            stage = .loggedIn
            onLoginSucceeded?(credential)
            return
        }
    }

    private func requestQRCodeID(using session: URLSession) async throws -> String {
        var request = makeRequest(path: "/wapi/zppassport/captcha/randkey")
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["code"] as? NSNumber)?.intValue == 0,
              let payload = object["zpData"] as? [String: Any],
              let qrID = payload["qrId"] as? String,
              !qrID.isEmpty else {
            throw LoginError.invalidResponse("获取 BOSS 登录二维码失败。")
        }
        return qrID
    }

    private func waitForScan(qrID: String, using session: URLSession, generation: UInt64) async throws -> Bool {
        do {
            let request = makeRequest(path: "/wapi/zppassport/qrcode/scan", queryItems: [
                URLQueryItem(name: "uuid", value: qrID)
            ])
            try validateGeneration(generation)
            updateScanListener(generation: generation, state: .armed)
            let (data, response) = try await session.data(for: request)
            try validateGeneration(generation)
            try validate(response)
            updateScanListener(generation: generation, state: .completed)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (object["scaned"] as? NSNumber)?.boolValue == true
        } catch let error as URLError where error.code == .timedOut {
            updateScanListener(generation: generation, state: .completed)
            return false
        } catch {
            updateScanListener(generation: generation, state: .failed)
            throw error
        }
    }

    private func updateScanListener(generation: UInt64, state: BossQRCodeScanListenerState) {
        guard !isInvalidated, loginGeneration == generation else { return }
        scanListenerGeneration = generation
        scanListenerState = state
    }

    private func waitForConfirmation(qrID: String, using session: URLSession) async throws -> Bool {
        do {
            let request = makeRequest(path: "/wapi/zppassport/qrcode/scanLogin", queryItems: [
                URLQueryItem(name: "qrId", value: qrID)
            ])
            let (_, response) = try await session.data(for: request)
            try validate(response)
            return true
        } catch let error as URLError where error.code == .timedOut {
            return false
        }
    }

    private func dispatchLogin(qrID: String, using session: URLSession) async throws {
        let request = makeRequest(path: "/wapi/zppassport/qrcode/dispatcher", queryItems: [
            URLQueryItem(name: "qrId", value: qrID),
            URLQueryItem(name: "pk", value: "header-login")
        ])
        let (_, response) = try await session.data(for: request)
        try validate(response)

        do {
            let (_, warmupResponse) = try await session.data(for: makeRequest(path: "/"))
            try validate(warmupResponse)
        } catch let error as URLError where error.code == .timedOut {
            return
        }
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 40
        request.setValue(BossBrowserIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.zhipin.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.zhipin.com/", forHTTPHeaderField: "Referer")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw LoginError.invalidResponse("BOSS 扫码服务返回异常状态。")
        }
    }

    private func validateGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard !isInvalidated, loginGeneration == generation else {
            throw CancellationError()
        }
    }

    private func makeQRCode(from value: String) throws -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else {
            throw LoginError.invalidResponse("生成二维码失败。")
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

}

private enum LoginError: LocalizedError {
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): message
        }
    }
}
