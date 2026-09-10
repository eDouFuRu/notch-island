import Foundation

public enum ScalarControlCommand: Equatable, Sendable {
    case refresh
    case showCurrent
    case relative(Float)
    case absolute(Float)
}

public enum ScalarControlFailure: Equatable, Sendable {
    case invalidValue, readUnavailable, writeFailed, readbackUnavailable, cancelled
}

public struct ScalarControlResult: Equatable, Sendable {
    public let value: Float?
    public let failure: ScalarControlFailure?
    public let shouldPresent: Bool
}

/// One read/write/readback transaction at a time, including repeated relative key presses.
@MainActor
public final class SerialScalarControl {
    private let read: @MainActor () async -> Float?
    private let write: @MainActor (Float) async -> Bool
    private let receive: @MainActor (ScalarControlResult) -> Void
    private struct PendingCommand {
        let command: ScalarControlCommand
        let isCurrent: @MainActor () -> Bool
    }
    private var commands: [PendingCommand] = []
    private var worker: Task<Void, Never>?

    public init(
        read: @escaping @MainActor () async -> Float?,
        write: @escaping @MainActor (Float) async -> Bool,
        receive: @escaping @MainActor (ScalarControlResult) -> Void
    ) {
        self.read = read
        self.write = write
        self.receive = receive
    }

    public func enqueue(_ command: ScalarControlCommand, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        commands.append(.init(command: command, isCurrent: isCurrent))
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while !commands.isEmpty {
                let command = commands.removeFirst()
                receive(await execute(command))
            }
            worker = nil
        }
    }

    /// Used by deterministic production tests; does not start another transaction.
    public func waitUntilIdle() async { await worker?.value }

    private func execute(_ pending: PendingCommand) async -> ScalarControlResult {
        guard pending.isCurrent() else { return .init(value: nil, failure: .cancelled, shouldPresent: false) }
        let command = pending.command
        let shouldPresent = command != .refresh
        guard let current = validated(await read()) else {
            return .init(value: nil, failure: .readUnavailable, shouldPresent: shouldPresent)
        }
        let target: Float
        switch command {
        case .refresh, .showCurrent:
            return .init(value: current, failure: nil, shouldPresent: shouldPresent)
        case .relative(let delta): target = current + delta
        case .absolute(let value): target = value
        }
        guard target.isFinite else {
            return .init(value: current, failure: .invalidValue, shouldPresent: shouldPresent)
        }
        // Hiding or suspending during the asynchronous read must cancel the upcoming write.
        guard pending.isCurrent() else { return .init(value: current, failure: .cancelled, shouldPresent: false) }
        let succeeded = await write(min(1, max(0, target)))
        let actual = validated(await read())
        let failure: ScalarControlFailure? = !succeeded ? .writeFailed : actual == nil ? .readbackUnavailable : nil
        return .init(value: actual, failure: failure, shouldPresent: shouldPresent)
    }

    private func validated(_ value: Float?) -> Float? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
}
