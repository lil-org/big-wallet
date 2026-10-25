// ∅ 2026 lil org

import Foundation
import Synchronization
#if canImport(XCTest) && canImport(Big_Wallet)
@testable import Big_Wallet
#endif

final class SafariRPCClient: Sendable {
    private enum AttemptResult: Sendable {
        case retryUnauthorized
        case completed(RPCResponseToExtension)
    }

    private let urlSession: URLSession
    private let authorizationProvider: AlchemyAuthorizationProviding

    init(urlSession: URLSession = .shared,
         authorizationProvider: AlchemyAuthorizationProviding = AlchemyJWTProvider.rpcAuthorizationProvider) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
    }

    @concurrent
    func send(
        endpoint: EthereumRPCEndpoint,
        request: ValidatedRPCRequest,
        execution: SafariRPCExecution
    ) async throws -> RPCResponseToExtension {
        do {
            try execution.checkCancellationAndDeadline()
            let requestAuthorization = RPCRequestAuthorization(
                url: endpoint.url,
                allowsAlchemyAuthorization: endpoint.allowsAlchemyAuthorization,
                provider: authorizationProvider
            )
            let authorization = try await requestAuthorization.acquire()
            try execution.checkCancellationAndDeadline()
            return try await performSend(
                endpoint: endpoint,
                rpcRequest: request,
                authorization: authorization,
                requestAuthorization: requestAuthorization,
                execution: execution
            )
        } catch {
            try execution.checkCancellationAndDeadline()
            if let failure = error as? SafariRPCFailure { throw failure }
            if error is CancellationError { throw error }
            throw SafariRPCFailure.transport
        }
    }

    private func performSend(
        endpoint: EthereumRPCEndpoint,
        rpcRequest: ValidatedRPCRequest,
        authorization: AlchemyAuthorization?,
        requestAuthorization: RPCRequestAuthorization,
        execution: SafariRPCExecution
    ) async throws -> RPCResponseToExtension {
        var authorization = authorization
        while true {
            try execution.checkCancellationAndDeadline()
            switch try await performAttempt(
                endpoint: endpoint, rpcRequest: rpcRequest, authorization: authorization,
                requestAuthorization: requestAuthorization, execution: execution
            ) {
            case .retryUnauthorized:
                guard let rejected = authorization else { throw SafariRPCFailure.transport }
                authorization = try await requestAuthorization.replacement(afterUnauthorized: rejected)
                try execution.checkCancellationAndDeadline()
                guard authorization != nil else { throw SafariRPCFailure.transport }
            case .completed(let result):
                return result
            }
        }
    }

    private func performAttempt(
        endpoint: EthereumRPCEndpoint,
        rpcRequest: ValidatedRPCRequest,
        authorization: AlchemyAuthorization?,
        requestAuthorization: RPCRequestAuthorization,
        execution: SafariRPCExecution
    ) async throws -> AttemptResult {
        var request = URLRequest(url: endpoint.url)
#if BW_SAFARI_VM_TESTING
        try SafariVMFixtures.shared.authorize(&request)
#endif
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rpcRequest.body
        authorization?.apply(to: &request)
        let lease = execution.responseBudget.acquire()
        defer { lease.release() }
        let transfer = SafariRPCResponseTransfer(execution: execution, lease: lease)
        let received: SafariRPCResponseTransfer.Received
        do {
            received = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    transfer.start(session: urlSession, request: request, continuation: continuation)
                }
            } onCancel: {
                transfer.cancel()
            }
            try execution.checkCancellationAndDeadline()
        } catch {
            if transfer.receivedUnauthorized, let authorization {
                await requestAuthorization.invalidate(afterUnauthorized: authorization)
            }
            throw error
        }
        if received.response.statusCode == 401, let authorization {
            if rpcRequest.allowsUnauthorizedReplay, requestAuthorization.reserveUnauthorizedRecovery() {
                return .retryUnauthorized
            }
            await requestAuthorization.invalidate(afterUnauthorized: authorization)
            try execution.checkCancellationAndDeadline()
        }
        // Exclude UTF-16/32 autodetection so parsing uses the encoding scanned below.
        guard !received.data.contains(0) else { throw SafariRPCFailure.transport }
        let jsonBytes = received.data.dropFirst(received.data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        try SafariRPCJSONPreflight.validate(
            jsonBytes, maximumTokens: execution.limits.maximumResponseTokens,
            tokenLimitFailure: .responseTooLarge, depthLimitFailure: .transport,
            checkCancellation: execution.checkCancellationAndDeadline
        )
        guard let correlated = Self.responseDictionary(from: received.data, expectedResponseID: rpcRequest.id),
              let result = RPCResponseToExtension(upstream: correlated, expectedResponseID: rpcRequest.id) else {
            throw SafariRPCFailure.transport
        }
        try execution.checkCancellationAndDeadline()
        return .completed(result)
    }

    private static func responseDictionary(from data: Data, expectedResponseID: Int) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if var response = object as? [String: Any] {
            if let responseID = response["id"], !(responseID is NSNull),
               !responseIDMatches(responseID, expectedResponseID: expectedResponseID) { return nil }
            response["id"] = expectedResponseID
            return response
        }
        guard let batch = object as? [Any] else { return nil }
        let matches = batch.compactMap { value -> [String: Any]? in
            guard let response = value as? [String: Any],
                  responseIDMatches(response["id"], expectedResponseID: expectedResponseID) else { return nil }
            return response
        }
        guard matches.count == 1 else { return nil }
        var match = matches[0]
        match["id"] = expectedResponseID
        return match
    }

    private static func responseIDMatches(_ value: Any?, expectedResponseID: Int) -> Bool {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number as? Int == expectedResponseID
        }
        if let string = value as? String { return Int(string) == expectedResponseID }
        return false
    }
}

private final class SafariRPCResponseTransfer: NSObject, URLSessionDataDelegate, Sendable {
    struct Received: Sendable {
        let response: HTTPURLResponse
        let data: Data
    }

    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Received, Error>?
        var response: HTTPURLResponse?
        var receivedUnauthorized = false
        var data = Data()
        var failure: (any Error)?
        var finished = false
    }

    private let state = Mutex(State())
    private let execution: SafariRPCExecution
    private let lease: SafariRPCResponseBudget.Lease

    var receivedUnauthorized: Bool { state.withLock { $0.receivedUnauthorized } }

    init(execution: SafariRPCExecution, lease: SafariRPCResponseBudget.Lease) {
        self.execution = execution
        self.lease = lease
        super.init()
    }

    func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<Received, Error>) {
        let task = session.dataTask(with: request)
        task.delegate = self
        do {
            try state.withLock { state in
                if let failure = state.failure { throw failure }
                guard !state.finished else { throw CancellationError() }
                try execution.markDispatched()
                state.task = task
                state.continuation = continuation
            }
            task.resume()
        } catch {
            state.withLock { $0.finished = true }
            task.cancel()
            continuation.resume(throwing: error)
        }
    }

    func cancel() { stop(with: CancellationError()) }

    private func stop(with failure: any Error) {
        let task = state.withLock { state -> URLSessionDataTask? in
            guard !state.finished else { return nil }
            state.failure = state.failure ?? failure
            state.data = Data()
            lease.release()
            return state.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let response = response as? HTTPURLResponse else { throw SafariRPCFailure.transport }
            if response.statusCode == 401 {
                state.withLock { if !$0.finished { $0.receivedUnauthorized = true } }
            }
            try execution.checkCancellationAndDeadline()
            guard response.expectedContentLength < 0 ||
                    response.expectedContentLength <= Int64(execution.limits.maximumResponseBytes) else {
                throw SafariRPCFailure.responseTooLarge
            }
            let accepted = state.withLock { state in
                guard !state.finished, state.failure == nil else { return false }
                state.response = response
                return true
            }
            completionHandler(accepted ? .allow : .cancel)
        } catch {
            stop(with: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try state.withLock { state in
                guard !state.finished, state.failure == nil else { return }
                try execution.checkCancellationAndDeadline()
                guard state.response != nil else { throw SafariRPCFailure.transport }
                guard data.count <= execution.limits.maximumResponseBytes - state.data.count else {
                    throw SafariRPCFailure.responseTooLarge
                }
                try lease.reserve(data.count)
                state.data.append(data)
            }
        } catch { stop(with: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion = state.withLock { state -> (CheckedContinuation<Received, Error>, Result<Received, Error>)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            let result: Result<Received, Error>
            if let failure = state.failure ?? error {
                result = .failure(failure)
            } else {
                do {
                    try execution.checkCancellationAndDeadline()
                    guard let response = state.response else { throw SafariRPCFailure.transport }
                    result = .success(Received(response: response, data: state.data))
                } catch { result = .failure(error) }
            }
            state.task = nil
            state.continuation = nil
            state.response = nil
            state.data = Data()
            return (continuation, result)
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        stop(with: SafariRPCFailure.transport)
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }
}
