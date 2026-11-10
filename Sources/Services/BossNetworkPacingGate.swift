import Foundation

/// 所有显式 BOSS HTTP 和 WebSocket 操作共用进程级调度。
actor BossNetworkPacingGate {
    static let shared = BossNetworkPacingGate()
    @TaskLocal static var expedited = false

    private struct Request {
        let isWrite: Bool
        let expedited: Bool
        let readJitter: Int
        let writeJitter: Int
        let notBefore: Date
    }

    private var lastDispatchedAt: Date?
    private var lastWriteAt: Date?
    private var lastStandardDispatchedAt: Date?
    private var lastStandardWriteAt: Date?
    private var sequence: UInt64 = 0
    private var waiting: [UInt64: Request] = [:]

    func wait(
        isWrite: Bool,
        discriminator: String,
        notBefore: Date = .distantPast,
        isStillValid: @Sendable () async -> Bool = { true }
    ) async throws {
        sequence &+= 1
        let requestSequence = sequence
        let expedited = Self.expedited
        let request = Request(
            isWrite: isWrite,
            expedited: expedited,
            readJitter: BossRequestPacingPolicy.jitterSeconds(
                discriminator: discriminator, sequence: requestSequence, isWrite: false, expedited: expedited
            ),
            writeJitter: BossRequestPacingPolicy.jitterSeconds(
                discriminator: discriminator, sequence: requestSequence, isWrite: true, expedited: expedited
            ),
            notBefore: notBefore
        )
        waiting[requestSequence] = request
        defer { waiting[requestSequence] = nil }

        while true {
            try Task.checkCancellation()
            guard await isStillValid() else { throw CancellationError() }
            try Task.checkCancellation()

            let now = Date()
            let delay = nextAllowedAt(for: request, now: now).timeIntervalSince(now)
            if delay > 0 {
                // 及时检查账号是否退出，同时保持原调度间隔。
                try await Task.sleep(nanoseconds: UInt64(min(delay, 0.25) * 1_000_000_000))
                continue
            }
            // 只为即将到期的旧请求让出时隙，写入长冷却期间仍可读取。
            let nextSlot = now.addingTimeInterval(1)
            if waiting.contains(where: {
                $0.key < requestSequence && nextAllowedAt(for: $0.value, now: now) <= nextSlot
            }) {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }

            // 最终校验与提交之间不挂起，确保一个时隙仅提交一次。
            lastDispatchedAt = now
            if isWrite { lastWriteAt = now }
            if !expedited {
                lastStandardDispatchedAt = now
                if isWrite { lastStandardWriteAt = now }
            }
            return
        }
    }

    private func nextAllowedAt(for request: Request, now: Date) -> Date {
        let sharedDue = BossRequestPacingPolicy.nextAllowedAt(
            lastDispatchedAt: lastDispatchedAt, lastWriteAt: lastWriteAt,
            isWrite: request.isWrite, readJitter: min(1, request.readJitter),
            writeJitter: min(1, request.writeJitter), now: now, expedited: true
        )
        guard !request.expedited else { return max(sharedDue, request.notBefore) }
        let standardDue = BossRequestPacingPolicy.nextAllowedAt(
            lastDispatchedAt: lastStandardDispatchedAt, lastWriteAt: lastStandardWriteAt,
            isWrite: request.isWrite, readJitter: request.readJitter, writeJitter: request.writeJitter, now: now
        )
        return max(sharedDue, standardDue, request.notBefore)
    }
}
