import Foundation
import Synchronization

struct HTTPTransportResponse: Sendable {
    let data: Data?
    let response: URLResponse?
    let error: (any Error)?
}

extension URLSession {
    func responsePreservingTransportError(
        for request: URLRequest,
        limits: NativeRPCResponseLimits = .live
    ) async throws -> HTTPTransportResponse {
        let transfer = NativeRPCResponseTransfer(limits: limits)
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

private final class NativeRPCResponseTransfer: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        var response: URLResponse?
        var data = Data()
        var finished = false
    }

    private struct Completion {
        let task: URLSessionDataTask?
        let continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        let result: Result<HTTPTransportResponse, Error>

        func resume(cancellingTask: Bool) {
            if cancellingTask { task?.cancel() }
            continuation?.resume(with: result)
        }
    }

    private let state = Mutex(State())
    private let limits: NativeRPCResponseLimits

    init(limits: NativeRPCResponseLimits) {
        self.limits = limits
        super.init()
    }

    func start(
        session: URLSession,
        request: URLRequest,
        continuation: CheckedContinuation<HTTPTransportResponse, Error>
    ) {
        let task = session.dataTask(with: request)
        task.delegate = self
        let started = state.withLock { state in
            guard !state.finished else { return false }
            state.task = task
            state.continuation = continuation
            return true
        }
        if started {
            task.resume()
        } else {
            task.cancel()
            continuation.resume(throwing: CancellationError())
        }
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
            guard response.expectedContentLength < 0 ||
                    response.expectedContentLength <= Int64(limits.maximumResponseBytes) else {
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
            guard data.count <= limits.maximumResponseBytes - state.data.count else {
                return Self.reject(&state, error: .responseTooLarge)
            }
            state.data.append(data)
            return nil
        }
        completion?.resume(cancellingTask: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock { state in
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
            return Self.reject(&state, error: .redirectRejected)
        }
        completionHandler(nil)
        completion?.resume(cancellingTask: true)
    }

    private static func reject(_ state: inout State, error: NativeRPCResponsePolicyError) -> Completion? {
        let response = HTTPTransportResponse(data: nil, response: state.response, error: error)
        return finish(&state, result: .success(response))
    }

    private static func finish(
        _ state: inout State,
        result: Result<HTTPTransportResponse, Error>
    ) -> Completion? {
        guard !state.finished else { return nil }
        state.finished = true
        let completion = Completion(task: state.task, continuation: state.continuation, result: result)
        state.task = nil
        state.continuation = nil
        state.response = nil
        state.data = Data()
        return completion
    }
}
