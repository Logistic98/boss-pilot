import Foundation

/// 所有显式 BOSS HTTP 和 WebSocket 操作共用进程级调度。
actor BossNetworkPacingGate {
    static let shared = BossNetworkPacingGate()
    @TaskLocal static var expedited = false
    @TaskLocal static var prioritizesGreeting = false

    private struct Request {
        let isWrite: Bool
        let expedited: Bool
        let prioritizesGreeting: Bool
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
        let queuedAt = Date()
        let expedited = Self.expedited
        let request = Request(
            isWrite: isWrite,
            expedited: expedited,
            prioritizesGreeting: Self.prioritizesGreeting,
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
            // 仅就绪的开聊请求优先；未来的开聊时隙不阻塞补货。
            let nextSlot = now.addingTimeInterval(1)
            if waiting.contains(where: {
                $0.key != requestSequence && nextAllowedAt(for: $0.value, now: now) <= nextSlot &&
                    ($0.value.prioritizesGreeting == request.prioritizesGreeting
                        ? $0.key < requestSequence : $0.value.prioritizesGreeting)
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
            if isWrite {
                fputs(String(format: "WRITE SLOT: kind=%@ seconds=%.2f fast=%d\n",
                             String(discriminator.split(separator: "|").first ?? "write"),
                             Date().timeIntervalSince(queuedAt), expedited ? 1 : 0), stderr)
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
