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
        let response = try await transfer.response(for: request, session: self)
        try Task.checkCancellation()
        return response
    }
}

final class HTTPResponseTransfer: NSObject, URLSessionDataDelegate, Sendable {
    private enum Mode: Sendable {
        case native(HTTPResponsePolicy, HTTPResponseTiming, deadline: ContinuousClock.Instant?)
        case safari(SafariRPCExecution, SafariRPCResponseBudget.Lease)

        var maximumResponseBytes: Int {
            switch self {
            case .native(let policy, _, _): policy.maximumResponseBytes
            case .safari(let execution, _): execution.limits.maximumResponseBytes
            }
        }

        var responseTooLarge: any Error {
            switch self {
            case .native: HTTPResponsePolicyError.responseTooLarge
            case .safari: SafariRPCFailure.responseTooLarge
            }
        }
    }

    private struct State {
        var task: URLSessionDataTask?
        var deadlineTask: Task<Void, Never>?
        var continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        var response: URLResponse?
        var receivedUnauthorized = false
        var data = Data()
        var failure: (any Error)?
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
    private let mode: Mode

    var receivedUnauthorized: Bool { state.withLock { $0.receivedUnauthorized } }

    init(policy: HTTPResponsePolicy, timing: HTTPResponseTiming) {
        mode = .native(policy, timing, deadline: policy.totalTimeout.map { timing.now().advanced(by: $0) })
        super.init()
    }

    init(execution: SafariRPCExecution, lease: SafariRPCResponseBudget.Lease) {
        mode = .safari(execution, lease)
        super.init()
    }

    func response(for request: URLRequest, session: URLSession) async throws -> HTTPTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.start(session: session, request: request, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(
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
            do {
                if let failure = state.failure { throw failure }
                switch mode {
                case .native: try checkCurrent()
                case .safari(let execution, _): try execution.markDispatched()
                }
                return (true, nil)
            } catch {
                return (true, finishFailure(&state, error: error))
            }
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
        if case .native(_, let timing, let deadline?) = mode {
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
            guard !state.finished, state.failure == nil else { return (false, nil) }
            guard !hasExpired else { return (false, stop(&state, with: HTTPResponsePolicyError.deadlineExceeded)) }
            return (true, nil)
        }
        dispatch.1?.resume(cancellingTask: true)
        if dispatch.0 { task.resume() }
    }

    private var hasExpired: Bool {
        guard case .native(_, let timing, let deadline?) = mode else { return false }
        return timing.now() >= deadline
    }

    private func checkCurrent() throws {
        switch mode {
        case .native:
            if hasExpired { throw HTTPResponsePolicyError.deadlineExceeded }
        case .safari(let execution, _):
            try execution.checkCancellationAndDeadline()
        }
    }

    private func expire() {
        let completion = state.withLock { state -> Completion? in
            guard hasExpired else { return nil }
            return stop(&state, with: HTTPResponsePolicyError.deadlineExceeded)
        }
        completion?.resume(cancellingTask: true)
    }

    private func cancel() {
        let completion = state.withLock { stop(&$0, with: CancellationError()) }
        completion?.resume(cancellingTask: true)
    }

    private func stop(_ state: inout State, with failure: any Error) -> Completion? {
        guard !state.finished else { return nil }
        switch mode {
        case .native:
            return finishFailure(&state, error: failure)
        case .safari(_, let lease):
            state.failure = state.failure ?? failure
            state.data = Data()
            lease.release()
            return Completion(task: state.task, deadlineTask: nil, continuation: nil, result: .failure(failure))
        }
    }

    private func finishFailure(_ state: inout State, error: any Error) -> Completion? {
        let result: Result<HTTPTransportResponse, Error>
        switch mode {
        case .native where !(error is CancellationError):
            result = .success(HTTPTransportResponse(data: nil, response: state.response, error: error))
        case .native, .safari:
            result = .failure(error)
        }
        return Self.finish(&state, result: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let decision = state.withLock { state -> (Bool, Completion?) in
            guard !state.finished else { return (false, nil) }
            if (response as? HTTPURLResponse)?.statusCode == 401 { state.receivedUnauthorized = true }
            if case .native = mode { state.response = response }
            guard state.failure == nil else { return (false, nil) }
            do {
                if case .safari = mode, !(response is HTTPURLResponse) { throw SafariRPCFailure.transport }
                try checkCurrent()
                guard response.expectedContentLength < 0 ||
                        response.expectedContentLength <= Int64(mode.maximumResponseBytes) else {
                    throw mode.responseTooLarge
                }
                state.response = response
                return (true, nil)
            } catch {
                return (false, stop(&state, with: error))
            }
        }
        completionHandler(decision.0 ? .allow : .cancel)
        decision.1?.resume(cancellingTask: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let completion = state.withLock { state -> Completion? in
            guard !state.finished, state.failure == nil else { return nil }
            do {
                try checkCurrent()
                if case .safari = mode, state.response == nil { throw SafariRPCFailure.transport }
                guard data.count <= mode.maximumResponseBytes - state.data.count else { throw mode.responseTooLarge }
                if case .safari(_, let lease) = mode { try lease.reserve(data.count) }
                state.data.append(data)
                return nil
            } catch {
                return stop(&state, with: error)
            }
        }
        completion?.resume(cancellingTask: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock { state -> Completion? in
            guard !state.finished else { return nil }
            do {
                switch mode {
                case .native:
                    try checkCurrent()
                    if let error {
                        let response = HTTPTransportResponse(data: nil, response: state.response, error: error)
                        return Self.finish(&state, result: .success(response))
                    }
                case .safari:
                    if let failure = state.failure ?? error { throw failure }
                    try checkCurrent()
                    guard state.response != nil else { throw SafariRPCFailure.transport }
                }
                let response = HTTPTransportResponse(data: state.data, response: state.response, error: nil)
                return Self.finish(&state, result: .success(response))
            } catch {
                return finishFailure(&state, error: error)
            }
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
            switch mode {
            case .native:
                state.response = response
                return stop(&state, with: hasExpired ? HTTPResponsePolicyError.deadlineExceeded : HTTPResponsePolicyError.redirectRejected)
            case .safari:
                return stop(&state, with: SafariRPCFailure.transport)
            }
        }
        completionHandler(nil)
        completion?.resume(cancellingTask: true)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        if case .safari = mode { completionHandler(nil) }
        else { completionHandler(proposedResponse) }
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
