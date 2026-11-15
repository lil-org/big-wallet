// ∅ 2026 lil org

import Foundation
import WalletDomain

public final class SafariRPCClient: Sendable {
    private enum AttemptResult: Sendable {
        case retryUnauthorized
        case completed(RPCResponseToExtension)
    }

    private let urlSession: URLSession
    private let authorizeRequest: @Sendable (inout URLRequest) throws -> Void
    private let authorizationProvider: AlchemyAuthorizationProviding

    public init(urlSession: URLSession,
         authorizationProvider: any AlchemyAuthorizationProviding,
         authorizeRequest: @escaping @Sendable (inout URLRequest) throws -> Void = { _ in }) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
        self.authorizeRequest = authorizeRequest
    }

    @concurrent
    public func send(
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
        try authorizeRequest(&request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rpcRequest.body
        authorization?.apply(to: &request)
        let lease = execution.responseBudget.acquire()
        defer { lease.release() }
        let transfer = HTTPResponseTransfer(execution: execution, lease: lease)
        let response: HTTPURLResponse
        let data: Data
        do {
            let received = try await transfer.response(for: request, session: urlSession)
            guard let receivedResponse = received.response as? HTTPURLResponse,
                  let receivedData = received.data else {
                throw SafariRPCFailure.transport
            }
            response = receivedResponse
            data = receivedData
            try execution.checkCancellationAndDeadline()
        } catch {
            if transfer.receivedUnauthorized, let authorization {
                await requestAuthorization.invalidate(afterUnauthorized: authorization)
            }
            throw error
        }
        if response.statusCode == 401, let authorization {
            if rpcRequest.allowsUnauthorizedReplay, requestAuthorization.reserveUnauthorizedRecovery() {
                return .retryUnauthorized
            }
            await requestAuthorization.invalidate(afterUnauthorized: authorization)
            try execution.checkCancellationAndDeadline()
        }
        // Exclude UTF-16/32 autodetection so parsing uses the encoding scanned below.
        guard !data.contains(0) else { throw SafariRPCFailure.transport }
        let jsonBytes = data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        try SafariRPCJSONPreflight.validate(
            jsonBytes, maximumTokens: execution.limits.maximumResponseTokens,
            tokenLimitFailure: .responseTooLarge, depthLimitFailure: .transport,
            checkCancellation: execution.checkCancellationAndDeadline
        )
        guard let correlated = Self.responseDictionary(from: data, expectedResponseID: rpcRequest.id),
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
