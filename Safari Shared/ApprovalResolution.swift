import Foundation

actor ApprovalResolution<Value: Sendable> {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value, Never>)
        case ready(Value)
        case consumed
    }

    private var state = State.empty

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

    func value(
        timeoutValue: Value,
        waitForTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let operationTask = Task {
            resolve(await operation())
        }
        let timeoutTask = Task {
            await waitForTimeout()
            guard !Task.isCancelled else { return }
            resolve(timeoutValue) {
                operationTask.cancel()
            }
        }
        let result = await value()
        timeoutTask.cancel()
        operationTask.cancel()
        return result
    }

    @discardableResult
    func resolve(
        _ value: Value,
        beforeResume: @Sendable () -> Void = {}
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
