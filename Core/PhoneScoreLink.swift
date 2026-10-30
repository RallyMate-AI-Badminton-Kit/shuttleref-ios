import Foundation

/// Implement on the existing central/connection coordinator, never a second CBCentralManager.
/// Notifications are a separate input; readScoreState must not be completed by EVENT notify.
@MainActor protocol RacketScoreTransport: AnyObject {
    func writeControlFrame(_ frame: Data) async throws
    func readScoreState() async throws -> Data
}

/// Hardware-independent integration harness. No automatic task/timer: the foreground App
/// coordinator calls tick every 1000 ms using a monotonic clock and forwards EVENT only.
@MainActor final class PhoneScoreLink {
    private let session: PhoneMatchSession; private let transport: RacketScoreTransport
    private let connection: UUID; private let clock: () -> UInt64
    private var assembler = RacketScoreAssembler(); private var transaction: UInt8 = 0
    private var tail: Task<Void,Error>?; private var generation = UUID(); private var closed = false
    init(session: PhoneMatchSession,transport: RacketScoreTransport,connection: UUID,clock: @escaping () -> UInt64) {
        self.session = session; self.transport = transport; self.connection = connection; self.clock = clock
    }
    private func serial(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail, captured = generation
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard !self.closed, self.generation == captured else { throw PhoneScoreError.invalidState }
            try await operation()
        }
        tail = task; try await task.value
    }
    func send(_ message: RacketScoreMessage) async throws {
        try await serial { try await self.write(message) }
    }
    private func write(_ message: RacketScoreMessage) async throws {
        let captured = generation
        guard session.maySend(message) else { throw PhoneScoreError.invalidState }
        let frames = try RacketScoreWire.frames(RacketScoreWire.encode(message),transaction:transaction)
        transaction &+= 1
        for frame in frames {
            guard generation == captured, !closed, session.mayContinue(message) else { throw PhoneScoreError.invalidState }
            try await transport.writeControlFrame(frame)
        }
    }
    private func heartbeat() async throws {
        try await serial {
            // Read the lease after earlier IO/actions finish, not before waiting in the queue.
            while true {
                let message = try self.session.ready(now:self.clock())
                try await self.write(message)
                let latest = try self.session.ready(now:self.clock())
                if latest.number("lease") != message.number("lease") { continue }
                try self.session.readyDelivered(lease:message.number("lease"),now:self.clock())
                break
            }
        }
    }
    func notification(_ frame: Data) async throws {
        guard !closed else { return }
        do {
            guard let data = try assembler.append(frame,now:clock()) else { return }
            let message = try RacketScoreWire.decode(data)
            switch message.type {
            case "configured":
                try session.configured(message,connection:connection); try await heartbeat()
            case "event":
                let ack = try session.receive(message,connection:connection,now:clock())
                guard session.canSend(ack,connection:connection) else { return }
                try await send(ack.wire()) // The DB transaction has already completed here.
                if !session.needsReview && !session.storageUncertain { try await heartbeat() }
            default: throw PhoneScoreError.invalidWire
            }
        } catch { session.requireReview(); throw error }
    }
    func tick() async throws {
        guard !closed, !session.needsReview, !session.storageUncertain else { return }
        do {
            try await serial {
                let raw = try await self.transport.readScoreState()
                try self.session.observe(RacketScoreWire.state(raw),connection:self.connection,now:self.clock())
            }
            if !session.needsReview { try await heartbeat() }
        } catch { session.requireReview(); throw error }
    }
    func background() async {
        generation = UUID(); assembler.reset()
        let stop = session.stop(); session.background() // Invalidate acceptance BEFORE the asynchronous write.
        if let stop { try? await send(stop) }
    }
    func disconnected() { closed = true; generation = UUID(); assembler.reset(); session.disconnected() }
}
