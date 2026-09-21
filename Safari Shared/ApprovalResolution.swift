import Foundation

@MainActor
final class ApprovalResolution<Value> {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value, Never>)
        case ready(Value)
        case consumed
    }

    private var state = State.empty

    nonisolated init() {}

    func value() async -> Value {
        switch state {
        case .empty:
            return await withCheckedContinuation { continuation in
                state = .waiting(continuation)
            }
        case .ready(let value):
            state = .consumed
            return value
        case .waiting, .consumed:
            preconditionFailure("Approval resolution permits one waiter")
        }
    }

    @discardableResult
    func resolve(
        _ value: Value,
        beforeResume: () -> Void = {}
    ) -> Bool {
        let continuation: CheckedContinuation<Value, Never>?
        switch state {
        case .empty:
            state = .ready(value)
            continuation = nil
        case .waiting(let waiting):
            state = .consumed
            continuation = waiting
        case .ready, .consumed:
            return false
        }
        beforeResume()
        continuation?.resume(returning: value)
        return true
    }
}
