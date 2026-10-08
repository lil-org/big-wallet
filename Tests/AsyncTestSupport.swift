import Foundation
import Synchronization
import XCTest

final class TestGate<Value: Sendable>: Sendable {
    private enum State {
        case waiting([CheckedContinuation<Value, Never>])
        case resolved(Value)
    }

    private let state = Mutex(State.waiting([]))

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Value? in
                switch state {
                case .waiting(var waiters):
                    waiters.append(continuation)
                    state = .waiting(waiters)
                    return nil
                case .resolved(let value):
                    return .some(value)
                }
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>]? in
            guard case .waiting(let waiters) = state else { return nil }
            state = .resolved(value)
            return waiters
        }
        guard let waiters else { return false }
        waiters.forEach { $0.resume(returning: value) }
        return true
    }
}

final class TestDeferred<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, Error>?
        var continuation: CheckedContinuation<Value, Error>?
        var hasConsumer = false
        var delivered = false
        var isCancelled = false
    }

    private let state = Mutex(State())
    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Value, Error>? in
                    precondition(!state.hasConsumer, "A deferred test result has one consumer")
                    state.hasConsumer = true
                    if Task.isCancelled {
                        state.isCancelled = true
                        state.result = .failure(CancellationError())
                    }
                    if let result = state.result {
                        state.delivered = true
                        state.result = nil
                        return result
                    }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let resolution = state.withLock { state -> (Bool, CheckedContinuation<Value, Error>?) in
            guard !state.delivered, state.result == nil, !state.isCancelled else { return (false, nil) }
            let continuation = state.continuation
            state.continuation = nil
            if continuation != nil { state.delivered = true }
            else { state.result = result }
            return (true, continuation)
        }
        resolution.1?.resume(with: result)
        return resolution.0
    }

    private func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Value, Error>? in
            state.isCancelled = true
            guard !state.delivered else { return nil }
            let continuation = state.continuation
            state.continuation = nil
            if continuation != nil { state.delivered = true }
            else { state.result = .failure(CancellationError()) }
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

final class TestClock: Sendable {
    struct Sleep: Sendable {
        let id: UUID
        let startedAt: UInt64
        let deadline: UInt64
        var durationNanoseconds: UInt64 { deadline - startedAt }
    }

    private struct State {
        var date: Date
        var uptime: UInt64
        var sleepers = [UUID: (Sleep, TestDeferred<Void>)]()
        var registrations = [Sleep]()
        var activeSleeps = Set<UUID>()
        var onRegistration: (@Sendable (Sleep) -> Void)?
        var onCompletion: (@Sendable (Sleep) -> Void)?
    }

    private let state: Mutex<State>
    private let initialUptime: UInt64
    private let anchor = ContinuousClock.now

    init(date: Date = Date(timeIntervalSince1970: 1_800_000_000), uptimeNanoseconds: UInt64 = 1_000_000_000) {
        state = Mutex(State(date: date, uptime: uptimeNanoseconds))
        initialUptime = uptimeNanoseconds
    }

    var date: Date { state.withLock { $0.date } }
    var uptimeNanoseconds: UInt64 { state.withLock { $0.uptime } }
    var instant: ContinuousClock.Instant {
        let elapsed = uptimeNanoseconds - initialUptime
        return anchor.advanced(by: .seconds(Int64(elapsed / 1_000_000_000)) + .nanoseconds(Int64(elapsed % 1_000_000_000)))
    }
    var registrations: [Sleep] { state.withLock { $0.registrations } }
    var activeSleepCount: Int { state.withLock { $0.activeSleeps.count } }
    var pendingSleeps: [Sleep] { state.withLock { $0.sleepers.values.map(\.0).sorted { $0.deadline < $1.deadline } } }

    var onRegistration: (@Sendable (Sleep) -> Void)? {
        get { state.withLock { $0.onRegistration } }
        set { state.withLock { $0.onRegistration = newValue } }
    }

    var onCompletion: (@Sendable (Sleep) -> Void)? {
        get { state.withLock { $0.onCompletion } }
        set { state.withLock { $0.onCompletion = newValue } }
    }

    func setDate(_ date: Date) { state.withLock { $0.date = date } }

    func advance(to date: Date) {
        let ready = state.withLock { state -> [TestDeferred<Void>] in
            let seconds = max(0, date.timeIntervalSince(state.date))
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            let (uptime, overflow) = state.uptime.addingReportingOverflow(nanoseconds)
            state.uptime = overflow ? UInt64.max : uptime
            state.date = date
            return Self.removeDueSleepers(from: &state)
        }
        ready.forEach { $0.resolve(.success(())) }
    }

    func advance(by nanoseconds: UInt64) { advanceUptime(by: nanoseconds, advancingDate: true) }
    func advanceUptime(by nanoseconds: UInt64) { advanceUptime(by: nanoseconds, advancingDate: false) }

    func advance(to uptime: UInt64) {
        let ready = state.withLock { state -> [TestDeferred<Void>] in
            guard uptime >= state.uptime else { return [] }
            state.date += Double(uptime - state.uptime) / 1_000_000_000
            state.uptime = uptime
            return Self.removeDueSleepers(from: &state)
        }
        ready.forEach { $0.resolve(.success(())) }
    }

    private func advanceUptime(by nanoseconds: UInt64, advancingDate: Bool) {
        let ready = state.withLock { state -> [TestDeferred<Void>] in
            let (next, overflow) = state.uptime.addingReportingOverflow(nanoseconds)
            let uptime = overflow ? UInt64.max : next
            if advancingDate { state.date += Double(uptime - state.uptime) / 1_000_000_000 }
            state.uptime = uptime
            return Self.removeDueSleepers(from: &state)
        }
        ready.forEach { $0.resolve(.success(())) }
    }

    private static func removeDueSleepers(from state: inout State) -> [TestDeferred<Void>] {
        let due = state.sleepers.filter { $0.value.0.deadline <= state.uptime }
        due.keys.forEach { state.sleepers.removeValue(forKey: $0) }
        return due.values.map(\.1)
    }

    func sleep(for nanoseconds: UInt64) async throws {
        let (deadline, overflow) = uptimeNanoseconds.addingReportingOverflow(nanoseconds)
        try await sleep(until: overflow ? UInt64.max : deadline)
    }

    func sleep(until deadline: UInt64) async throws {
        try Task.checkCancellation()
        let deferred = TestDeferred<Void>()
        let registration = state.withLock { state -> (Sleep, (@Sendable (Sleep) -> Void)?)? in
            guard deadline > state.uptime else { return nil }
            let sleep = Sleep(id: UUID(), startedAt: state.uptime, deadline: deadline)
            state.sleepers[sleep.id] = (sleep, deferred)
            state.registrations.append(sleep)
            state.activeSleeps.insert(sleep.id)
            return (sleep, state.onRegistration)
        }
        guard let (sleep, onRegistration) = registration else { return }
        onRegistration?(sleep)
        defer {
            let onCompletion = state.withLock { state in
                state.sleepers.removeValue(forKey: sleep.id)
                state.activeSleeps.remove(sleep.id)
                return state.onCompletion
            }
            onCompletion?(sleep)
        }
        try await deferred.value()
    }

    @discardableResult
    func wake(_ id: UUID) -> Bool {
        let deferred = state.withLock { $0.sleepers.removeValue(forKey: id)?.1 }
        return deferred?.resolve(.success(())) ?? false
    }
}

@discardableResult
func expectEventually(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !Task.isCancelled {
        if await condition() { return true }
        guard ContinuousClock.now < deadline else { break }
        do { try await Task.sleep(for: .milliseconds(1)) }
        catch { break }
    }
    XCTFail("Condition did not become true before the deadline", file: file, line: line)
    return false
}
