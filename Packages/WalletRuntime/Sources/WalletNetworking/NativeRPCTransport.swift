import Foundation
import Synchronization

struct HTTPTransportResponse: Sendable {
    let data: Data?
    let response: URLResponse?
    let error: (any Error)?
}

struct HTTPResponseTiming: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let live = HTTPResponseTiming(
        now: { ContinuousClock.now },
        sleepUntil: { try await ContinuousClock().sleep(until: $0) }
    )
}

extension URLSession {
    func responsePreservingTransportError(
        for request: URLRequest,
        policy: HTTPResponsePolicy = .nativeRPC,
        timing: HTTPResponseTiming = .live
    ) async throws -> HTTPTransportResponse {
        let transfer = HTTPResponseTransfer(policy: policy, timing: timing)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(session: self, request: request, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        return response
    }
}

private final class HTTPResponseTransfer: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var deadlineTask: Task<Void, Never>?
        var continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        var response: URLResponse?
        var data = Data()
        var finished = false
    }

    private struct Completion {
        let task: URLSessionDataTask?
        let deadlineTask: Task<Void, Never>?
        let continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        let result: Result<HTTPTransportResponse, Error>

        func resume(cancellingTask: Bool) {
            deadlineTask?.cancel()
            if cancellingTask { task?.cancel() }
            continuation?.resume(with: result)
        }
    }

    private let state = Mutex(State())
    private let policy: HTTPResponsePolicy
    private let timing: HTTPResponseTiming
    private let deadline: ContinuousClock.Instant?

    init(policy: HTTPResponsePolicy, timing: HTTPResponseTiming) {
        self.policy = policy
        self.timing = timing
        deadline = policy.totalTimeout.map { timing.now().advanced(by: $0) }
        super.init()
    }

    func start(
        session: URLSession,
        request: URLRequest,
        continuation: CheckedContinuation<HTTPTransportResponse, Error>
    ) {
        let task = session.dataTask(with: request)
        task.delegate = self
        let started = state.withLock { state -> (Bool, Completion?) in
            guard !state.finished else { return (false, nil) }
            state.task = task
            state.continuation = continuation
            return (true, hasExpired ? Self.reject(&state, error: .deadlineExceeded) : nil)
        }
        guard started.0 else {
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        if let completion = started.1 {
            completion.resume(cancellingTask: true)
            return
        }
        if let deadline {
            let timer = Task { [weak self, timing] in
                do { try await timing.sleepUntil(deadline) }
                catch { return }
                self?.expire()
            }
            let installed = state.withLock { state in
                guard !state.finished else { return false }
                state.deadlineTask = timer
                return true
            }
            if !installed { timer.cancel() }
        }
        let dispatch = state.withLock { state -> (Bool, Completion?) in
            guard !state.finished else { return (false, nil) }
            guard !hasExpired else { return (false, Self.reject(&state, error: .deadlineExceeded)) }
            return (true, nil)
        }
        dispatch.1?.resume(cancellingTask: true)
        if dispatch.0 { task.resume() }
    }

    private var hasExpired: Bool { deadline.map { timing.now() >= $0 } ?? false }

    private func expire() {
        let completion = state.withLock { state -> Completion? in
            guard hasExpired else { return nil }
            return Self.reject(&state, error: .deadlineExceeded)
        }
        completion?.resume(cancellingTask: true)
    }

    func cancel() {
        let completion = state.withLock { state in
            Self.finish(&state, result: .failure(CancellationError()))
        }
        completion?.resume(cancellingTask: true)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let decision = state.withLock { state -> (Bool, Completion?) in
            guard !state.finished else { return (false, nil) }
            state.response = response
            guard !hasExpired else {
                return (false, Self.reject(&state, error: .deadlineExceeded))
            }
            guard response.expectedContentLength < 0 ||
                    response.expectedContentLength <= Int64(policy.maximumResponseBytes) else {
                return (false, Self.reject(&state, error: .responseTooLarge))
            }
            return (true, nil)
        }
        completionHandler(decision.0 ? .allow : .cancel)
        decision.1?.resume(cancellingTask: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let completion = state.withLock { state -> Completion? in
            guard !state.finished else { return nil }
            guard !hasExpired else { return Self.reject(&state, error: .deadlineExceeded) }
            guard data.count <= policy.maximumResponseBytes - state.data.count else {
                return Self.reject(&state, error: .responseTooLarge)
            }
            state.data.append(data)
            return nil
        }
        completion?.resume(cancellingTask: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock { state -> Completion? in
            guard !state.finished else { return nil }
            guard !hasExpired else { return Self.reject(&state, error: .deadlineExceeded) }
            let response = HTTPTransportResponse(
                data: error == nil ? state.data : nil, response: state.response, error: error
            )
            return Self.finish(&state, result: .success(response))
        }
        completion?.resume(cancellingTask: false)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let completion = state.withLock { state -> Completion? in
            guard !state.finished else { return nil }
            state.response = response
            return Self.reject(&state, error: hasExpired ? .deadlineExceeded : .redirectRejected)
        }
        completionHandler(nil)
        completion?.resume(cancellingTask: true)
    }

    private static func reject(_ state: inout State, error: HTTPResponsePolicyError) -> Completion? {
        let response = HTTPTransportResponse(data: nil, response: state.response, error: error)
        return finish(&state, result: .success(response))
    }

    private static func finish(
        _ state: inout State,
        result: Result<HTTPTransportResponse, Error>
    ) -> Completion? {
        guard !state.finished else { return nil }
        state.finished = true
        let completion = Completion(task: state.task, deadlineTask: state.deadlineTask,
                                    continuation: state.continuation, result: result)
        state.task = nil
        state.deadlineTask = nil
        state.continuation = nil
        state.response = nil
        state.data = Data()
        return completion
    }
}
