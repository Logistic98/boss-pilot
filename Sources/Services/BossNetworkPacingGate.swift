import Foundation

/// 所有显式 BOSS HTTP 和 WebSocket 操作共用进程级调度，避免多账号绕过请求间隔。
actor BossNetworkPacingGate {
    static let shared = BossNetworkPacingGate()

    private var lastDispatchedAt: Date?
    private var lastWriteAt: Date?
    private var sequence: UInt64 = 0
    private var waitingWriteCount = 0

    func wait(
        isWrite: Bool,
        discriminator: String,
        isStillValid: @Sendable () async -> Bool = { true }
    ) async throws {
        sequence &+= 1
        let requestSequence = sequence
        if isWrite { waitingWriteCount += 1 }
        defer {
            if isWrite { waitingWriteCount -= 1 }
        }

        while true {
            try Task.checkCancellation()
            guard await isStillValid() else { throw CancellationError() }
            try Task.checkCancellation()

            // 等待中的写操作优先取得下一时隙，避免连续读取长期占用未来预算。
            if !isWrite, waitingWriteCount > 0 {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            let now = Date()
            let nextAllowedAt = BossRequestPacingPolicy.nextAllowedAt(
                lastDispatchedAt: lastDispatchedAt,
                lastWriteAt: lastWriteAt,
                isWrite: isWrite,
                readJitter: BossRequestPacingPolicy.jitterSeconds(
                    discriminator: discriminator, sequence: requestSequence, isWrite: false
                ),
                writeJitter: BossRequestPacingPolicy.jitterSeconds(
                    discriminator: discriminator, sequence: requestSequence, isWrite: true
                ),
                now: now
            )
            let delay = nextAllowedAt.timeIntervalSince(now)
            if delay > 0 {
                // 及时检查账号是否退出，同时保持原调度间隔。
                try await Task.sleep(nanoseconds: UInt64(min(delay, 0.25) * 1_000_000_000))
                continue
            }

            // 最终校验与提交之间不挂起，确保一个时隙仅提交一次。
            lastDispatchedAt = now
            if isWrite { lastWriteAt = now }
            return
        }
    }
}
