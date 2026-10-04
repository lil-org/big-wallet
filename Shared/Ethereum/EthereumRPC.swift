// ∅ 2026 lil org

import Foundation
import Synchronization

enum EthereumQuantity {

    private static let maximumHexQuantityDigits = 256

    static func parseUInt256(
        _ value: String,
        allowPrefixless: Bool = false
    ) -> BigUInt? {
        let hasPrefix = value.hasPrefix(String.hexPrefix) || value.hasPrefix("0X")
        guard hasPrefix || allowPrefixless else { return nil }
        let prefixLength = hasPrefix ? String.hexPrefix.utf8.count : 0
        let digits = value.utf8.dropFirst(prefixLength)
        guard (1...maximumHexQuantityDigits).contains(digits.count),
              digits.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...70).contains(byte)
                      || (97...102).contains(byte)
              }),
              digits.drop(while: { $0 == 48 }).count <= 64 else {
            return nil
        }
        return BigUInt(hexString: value)
    }

}

struct EthereumFeeHistory: Decodable, Equatable, Sendable {
    let baseFeePerGas: [String]
    let reward: [[String]]?
}

struct EthereumLatestBlock: Decodable, Equatable, Sendable {

    enum BaseFeeField: Equatable, Sendable {
        case missing
        case null
        case encoded(String)
    }

    let number: String?
    let baseFeeField: BaseFeeField

    init(number: String?, baseFeeField: BaseFeeField) {
        self.number = number
        self.baseFeeField = baseFeeField
    }

    private enum CodingKeys: String, CodingKey {
        case number
        case baseFeePerGas
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(String.self, forKey: .number)
        if !container.contains(.baseFeePerGas) {
            baseFeeField = .missing
        } else if try container.decodeNil(forKey: .baseFeePerGas) {
            baseFeeField = .null
        } else {
            baseFeeField = .encoded(
                try container.decode(String.self, forKey: .baseFeePerGas)
            )
        }
    }
}

extension EthereumFeeHistory {

    private enum CodingKeys: String, CodingKey {
        case baseFeePerGas
        case reward
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseFeePerGas = try container.decode([String].self, forKey: .baseFeePerGas)
        reward = try? container.decode([[String]].self, forKey: .reward)
    }
}

protocol EthereumFeeRPCClient: Sendable {
    func fetchChainID(endpoint: EthereumRPCEndpoint) async throws -> String
    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double]
    ) async throws -> EthereumFeeHistory
    func fetchMaxPriorityFeePerGas(endpoint: EthereumRPCEndpoint) async throws -> String
    func fetchLatestBlock(endpoint: EthereumRPCEndpoint) async throws -> EthereumLatestBlock
    func fetchGasPrice(endpoint: EthereumRPCEndpoint) async throws -> String
}

extension EthereumFeeRPCClient {
    func fetchChainID(endpoint: EthereumRPCEndpoint) async throws -> String {
        throw EthereumRPCError.serverError(-32_601, "eth_chainId is not implemented by this client")
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double]
    ) async throws -> EthereumFeeHistory {
        try await fetchFeeHistory(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: "latest",
            rewardPercentiles: rewardPercentiles
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double]
    ) async throws -> EthereumFeeHistory {
        throw EthereumRPCError.serverError(-32_601, "eth_feeHistory is not implemented by this client")
    }

    func fetchMaxPriorityFeePerGas(endpoint: EthereumRPCEndpoint) async throws -> String {
        throw EthereumRPCError.serverError(-32_601, "eth_maxPriorityFeePerGas is not implemented by this client")
    }

    func fetchLatestBlock(endpoint: EthereumRPCEndpoint) async throws -> EthereumLatestBlock {
        throw EthereumRPCError.serverError(-32_601, "eth_getBlockByNumber is not implemented by this client")
    }

    func fetchGasPrice(endpoint: EthereumRPCEndpoint) async throws -> String {
        throw EthereumRPCError.serverError(-32_601, "eth_gasPrice is not implemented by this client")
    }
}

protocol EthereumRPCClient: EthereumFeeRPCClient {
    func getBalance(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String
    func fetchNonce(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String
    func estimateGas(endpoint: EthereumRPCEndpoint, transaction: Transaction) async throws -> String
    func sendRawTransaction(endpoint: EthereumRPCEndpoint, signedTxData: String) async throws -> String
}

private struct RPCResponse<ResultValue: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String
    let result: ResultValue?
    let error: Failure?

    struct Failure: Decodable, Sendable {
        let code: Int
        let message: String
    }
}

enum EthereumRPCError: Error, Equatable, Sendable {
    case serverError(Int, String, dataJSON: String? = nil)
    case notSubmitted
    case unknown

    var dataJSON: String? {
        guard case .serverError(_, _, let dataJSON) = self else { return nil }
        return dataJSON
    }

    var isMethodNotFound: Bool {
        guard case .serverError(let code, _, _) = self else { return false }
        return code == -32_601
    }
}

struct HTTPTransportResponse: Sendable {
    let data: Data?
    let response: URLResponse?
    let error: (any Error)?
}

extension URLSession {
    func responsePreservingTransportError(
        for request: URLRequest,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> HTTPTransportResponse {
        let operation = HTTPTransportOperation()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = dataTask(with: request) { data, response, error in
                    operation.finish(HTTPTransportResponse(data: data, response: response, error: error))
                }
                task.delegate = delegate
                operation.start(task: task, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return response
    }
}

private final class HTTPTransportOperation: Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<HTTPTransportResponse, Error>?
        var isFinished = false
    }

    private let state = Mutex(State())

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<HTTPTransportResponse, Error>) {
        let canStart = state.withLock { state in
            guard !state.isFinished else { return false }
            state.task = task
            state.continuation = continuation
            return true
        }
        if canStart {
            task.resume()
        } else {
            task.cancel()
            continuation.resume(throwing: CancellationError())
        }
    }

    func finish(_ response: HTTPTransportResponse) {
        let continuation = state.withLock { state in
            guard !state.isFinished else { return Optional<CheckedContinuation<HTTPTransportResponse, Error>>.none }
            state.isFinished = true
            state.task = nil
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: response)
    }

    func cancel() {
        let resources = state.withLock {
            state -> (URLSessionDataTask?, CheckedContinuation<HTTPTransportResponse, Error>?) in
            guard !state.isFinished else { return (nil, nil) }
            state.isFinished = true
            let resources = (state.task, state.continuation)
            state.task = nil
            state.continuation = nil
            return resources
        }
        resources.0?.cancel()
        resources.1?.resume(throwing: CancellationError())
    }
}

final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let rejectedRedirect = Mutex(false)

    var didRejectRedirect: Bool { rejectedRedirect.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        rejectedRedirect.withLock { $0 = true }
        completionHandler(nil)
    }
}

final class EthereumRPC: EthereumRPCClient {
    private enum RetryPolicy: Sendable {
        case transientFailures
        case never

        func shouldRetry(statusCode: Int) -> Bool {
            self == .transientFailures && (statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode))
        }

        func failureBeforeDispatch(_ failure: Error) -> Error {
            self == .never ? EthereumRPCError.notSubmitted : failure
        }
    }

    private let urlSession: URLSession
    private let authorizationProvider: any AlchemyAuthorizationProviding
    private let waitForRetry: @Sendable () async throws -> Void

    init(
        urlSession: URLSession = URLSession(configuration: .default),
        authorizationProvider: any AlchemyAuthorizationProviding = AlchemyJWTProvider.shared,
        waitForRetry: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(500))
        }
    ) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
        self.waitForRetry = waitForRetry
    }

    func fetchChainID(endpoint: EthereumRPCEndpoint) async throws -> String {
        try await request(
            body: Self.body(method: "eth_chainId", params: []), endpoint: endpoint, retryPolicy: .transientFailures)
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double]
    ) async throws -> EthereumFeeHistory {
        try await request(
            body: Self.body(
                method: "eth_feeHistory",
                params: [String.hex(blockCount, withPrefix: true), newestBlock, rewardPercentiles]),
            endpoint: endpoint,
            retryPolicy: .transientFailures
        )
    }

    func fetchMaxPriorityFeePerGas(endpoint: EthereumRPCEndpoint) async throws -> String {
        try await request(
            body: Self.body(method: "eth_maxPriorityFeePerGas", params: []), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    func fetchLatestBlock(endpoint: EthereumRPCEndpoint) async throws -> EthereumLatestBlock {
        try await request(
            body: Self.body(method: "eth_getBlockByNumber", params: ["latest", false]), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    func fetchGasPrice(endpoint: EthereumRPCEndpoint) async throws -> String {
        try await request(
            body: Self.body(method: "eth_gasPrice", params: []), endpoint: endpoint, retryPolicy: .transientFailures)
    }

    func getBalance(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String {
        try await request(
            body: Self.body(method: "eth_getBalance", params: [address, "pending"]), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    func fetchNonce(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String {
        try await request(
            body: Self.body(method: "eth_getTransactionCount", params: [address, "pending"]), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    func estimateGas(endpoint: EthereumRPCEndpoint, transaction: Transaction) async throws -> String {
        try await request(
            body: Self.body(method: "eth_estimateGas", params: [Self.estimateGasTransactionObject(for: transaction)]),
            endpoint: endpoint, retryPolicy: .transientFailures)
    }

    func sendRawTransaction(endpoint: EthereumRPCEndpoint, signedTxData: String) async throws -> String {
        try await request(
            body: Self.body(method: "eth_sendRawTransaction", params: [signedTxData]), endpoint: endpoint,
            retryPolicy: .never)
    }

    private static func body(method: String, params: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
    }

    private func request<Value: Decodable & Sendable>(
        body: Data,
        endpoint: EthereumRPCEndpoint,
        retryPolicy: RetryPolicy
    ) async throws -> Value {
        try Task.checkCancellation()
        guard endpoint.url.scheme != nil else {
            throw retryPolicy.failureBeforeDispatch(EthereumRPCError.unknown)
        }
        var retryCount = 0
        var didAttemptAuthorizationRecovery = false

        while true {
            try Task.checkCancellation()
            var authorization: AlchemyAuthorization?
            var failure: Error = EthereumRPCError.unknown
            do {
                if endpoint.allowsAlchemyAuthorization {
                    authorization = try await authorizationProvider.authorization(for: endpoint.url)
                    guard authorization != nil else { throw EthereumRPCError.unknown }
                }
            } catch {
                try Task.checkCancellation()
                failure = retryPolicy.failureBeforeDispatch(error)
                guard retryPolicy == .transientFailures, retryCount <= 3 else { throw failure }
                retryCount += 1
                try await waitForRetry()
                continue
            }

            attempt: while true {
                try Task.checkCancellation()
                var request = URLRequest(url: endpoint.url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                authorization?.apply(to: &request)
                let redirectDelegate = NoRedirectSessionDelegate()
                let transport = try await urlSession.responsePreservingTransportError(
                    for: request, delegate: redirectDelegate)
                try Task.checkCancellation()
                guard !redirectDelegate.didRejectRedirect else { throw EthereumRPCError.unknown }
                guard let response = transport.response as? HTTPURLResponse else {
                    failure = EthereumRPCError.unknown
                    break attempt
                }
                let data = transport.data
                let decoded = data.flatMap { try? JSONDecoder().decode(RPCResponse<Value>.self, from: $0) }
                try Task.checkCancellation()
                if response.statusCode == 401, retryPolicy == .never {
                    if let rejected = authorization {
                        await authorizationProvider.invalidateAuthorization(
                            afterUnauthorized: rejected, for: endpoint.url)
                        try Task.checkCancellation()
                    }
                    if let result = decoded?.result { return result }
                    if let error = decoded?.error {
                        throw Self.serverError(code: error.code, message: error.message, responseData: data)
                    }
                    throw EthereumRPCError.unknown
                }
                if response.statusCode == 401, let rejected = authorization {
                    guard !didAttemptAuthorizationRecovery else {
                        await authorizationProvider.invalidateAuthorization(
                            afterUnauthorized: rejected, for: endpoint.url)
                        try Task.checkCancellation()
                        throw EthereumRPCError.unknown
                    }
                    didAttemptAuthorizationRecovery = true
                    do {
                        let replacement = try await authorizationProvider.replacementAuthorization(
                            afterUnauthorized: rejected, for: endpoint.url)
                        try Task.checkCancellation()
                        guard let replacement else {
                            failure = EthereumRPCError.unknown
                            break attempt
                        }
                        authorization = replacement
                        continue attempt
                    } catch {
                        try Task.checkCancellation()
                        failure = error
                        break attempt
                    }
                }
                if transport.error != nil {
                    failure = EthereumRPCError.unknown
                    break attempt
                }
                if let result = decoded?.result { return result }
                if let error = decoded?.error {
                    let rpcError = Self.serverError(code: error.code, message: error.message, responseData: data)
                    guard !Self.isTerminalRequestError(code: error.code),
                        retryPolicy.shouldRetry(statusCode: response.statusCode)
                    else { throw rpcError }
                    failure = rpcError
                    break attempt
                }
                if !(200..<300).contains(response.statusCode), !retryPolicy.shouldRetry(statusCode: response.statusCode)
                {
                    throw EthereumRPCError.unknown
                }
                failure = EthereumRPCError.unknown
                break attempt
            }
            guard retryPolicy == .transientFailures, retryCount <= 3 else { throw failure }
            retryCount += 1
            try await waitForRetry()
        }
    }

    static func estimateGasTransactionObject(for transaction: Transaction) -> [String: Any] {
        var dict: [String: Any] = ["from": transaction.from, "data": transaction.data]
        if !transaction.to.isEmpty { dict["to"] = transaction.to }
        switch transaction.preparedFee {
        case .legacy(let gasPrice):
            dict["gasPrice"] = gasPrice.toHexString(withPrefix: true)
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            dict["type"] = "0x2"
            dict["maxPriorityFeePerGas"] =
                maxPriorityFeePerGas.toHexString(withPrefix: true)
            dict["maxFeePerGas"] = maxFeePerGas.toHexString(withPrefix: true)
            dict["accessList"] = transaction.accessList.map { entry in
                [
                    "address": entry.addressHexString,
                    "storageKeys": entry.storageKeyHexStrings
                ] as [String: Any]
            }
        case .none:
            break
        }
        if let gas = transaction.gas {
            dict["gas"] = transaction.gasLimitValue?.toHexString(withPrefix: true) ?? gas
        }
        if let value = transaction.value, value != String.hexPrefix, value != "0" {
            dict["value"] = EthereumQuantity.parseUInt256(value, allowPrefixless: true)?
                .toHexString(withPrefix: true) ?? value
        }
        return dict
    }
    
    private static func serverError(
        code: Int,
        message: String,
        responseData: Data?
    ) -> EthereumRPCError {
        .serverError(
            code,
            message,
            dataJSON: errorDataJSON(from: responseData)
        )
    }

    private static func errorDataJSON(from responseData: Data?) -> String? {
        guard let responseData,
              let response = try? JSONSerialization.jsonObject(
                  with: responseData,
                  options: [.fragmentsAllowed]
              ) as? [String: Any],
              let error = response["error"] as? [String: Any],
              let value = error["data"] else {
            return nil
        }

        guard let encoded = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys]
        ) else {
            return nil
        }
        return String(data: encoded, encoding: .utf8)
    }

    private static func isTerminalRequestError(code: Int) -> Bool {
        switch code {
        case -32_700, -32_600, -32_601, -32_602:
            return true
        default:
            return false
        }
    }

}
