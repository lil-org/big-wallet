import Foundation

actor ApprovalResolution<Value: Sendable> {
    enum CallerCancellation: Sendable {
        case ignore
        case resolveTimeout
    }

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
        callerCancellation: CallerCancellation,
        waitForTimeout: (@Sendable () async -> Void)? = nil,
        onDiscardedValue: @escaping @Sendable (Value) -> Void = { _ in },
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        if case .resolveTimeout = callerCancellation, Task.isCancelled {
            resolve(timeoutValue)
            return await value()
        }
        let operationTask = Task.detached {
            let result = await operation()
            if await self.resolve(result) == false {
                onDiscardedValue(result)
            }
        }
        let timeoutTask = waitForTimeout.map { waitForTimeout in
            Task.detached {
                await waitForTimeout()
                guard !Task.isCancelled else { return }
                await self.resolve(timeoutValue) {
                    operationTask.cancel()
                }
            }
        }
        defer {
            timeoutTask?.cancel()
            operationTask.cancel()
        }
        return await withTaskCancellationHandler {
            await value()
        } onCancel: {
            guard case .resolveTimeout = callerCancellation else { return }
            operationTask.cancel()
            Task.detached { await self.resolve(timeoutValue) }
        }
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
