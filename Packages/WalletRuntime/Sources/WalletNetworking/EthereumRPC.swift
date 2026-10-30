// ∅ 2026 lil org

import Foundation
import WalletDomain

public protocol EthereumFeeRPCClient: Sendable {
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

public extension EthereumFeeRPCClient {
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

public protocol EthereumRPCClient: EthereumFeeRPCClient {
    func getBalance(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String
    func fetchNonce(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String
    func estimateGas(endpoint: EthereumRPCEndpoint, transaction: Transaction) async throws -> String
    func sendRawTransaction(endpoint: EthereumRPCEndpoint, signedTxData: String) async throws -> String
}

private struct RPCResponse<ResultValue: Decodable & Sendable>: Decodable, Sendable {
    let result: ResultValue?
    let error: Failure?

    struct Failure: Decodable, Sendable {
        let code: Int
        let message: String
    }
}

public final class EthereumRPC: EthereumRPCClient {
    private static let requestID = 1

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
    private let authorizeRequest: @Sendable (inout URLRequest) throws -> Void
    private let waitForRetry: @Sendable () async throws -> Void

    public init(
        urlSession: URLSession = WalletHTTPSession.make(),
        authorizationProvider: any AlchemyAuthorizationProviding,
        authorizeRequest: @escaping @Sendable (inout URLRequest) throws -> Void = { _ in },
        waitForRetry: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(500))
        }
    ) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
        self.waitForRetry = waitForRetry
        self.authorizeRequest = authorizeRequest
    }

    public func fetchChainID(endpoint: EthereumRPCEndpoint) async throws -> String {
        try await request(
            body: Self.body(method: "eth_chainId", params: []), endpoint: endpoint, retryPolicy: .transientFailures)
    }

    public func fetchFeeHistory(
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

    public func fetchMaxPriorityFeePerGas(endpoint: EthereumRPCEndpoint) async throws -> String {
        try await request(
            body: Self.body(method: "eth_maxPriorityFeePerGas", params: []), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    public func fetchLatestBlock(endpoint: EthereumRPCEndpoint) async throws -> EthereumLatestBlock {
        try await request(
            body: Self.body(method: "eth_getBlockByNumber", params: ["latest", false]), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    public func fetchGasPrice(endpoint: EthereumRPCEndpoint) async throws -> String {
        try await request(
            body: Self.body(method: "eth_gasPrice", params: []), endpoint: endpoint, retryPolicy: .transientFailures)
    }

    public func getBalance(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String {
        try await request(
            body: Self.body(method: "eth_getBalance", params: [address, "pending"]), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    public func fetchNonce(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String {
        try await request(
            body: Self.body(method: "eth_getTransactionCount", params: [address, "pending"]), endpoint: endpoint,
            retryPolicy: .transientFailures)
    }

    public func estimateGas(endpoint: EthereumRPCEndpoint, transaction: Transaction) async throws -> String {
        try await request(
            body: Self.body(method: "eth_estimateGas", params: [Self.estimateGasTransactionObject(for: transaction)]),
            endpoint: endpoint, retryPolicy: .transientFailures)
    }

    public func sendRawTransaction(endpoint: EthereumRPCEndpoint, signedTxData: String) async throws -> String {
        try await request(
            body: Self.body(method: "eth_sendRawTransaction", params: [signedTxData]), endpoint: endpoint,
            retryPolicy: .never)
    }

    private static func body(method: String, params: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
    }

    @concurrent
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
        let requestAuthorization = RPCRequestAuthorization(
            url: endpoint.url,
            allowsAlchemyAuthorization: endpoint.allowsAlchemyAuthorization,
            provider: authorizationProvider
        )

        while true {
            try Task.checkCancellation()
            var authorization: AlchemyAuthorization?
            var failure: Error = EthereumRPCError.unknown
            do {
                authorization = try await requestAuthorization.acquire()
                if endpoint.allowsAlchemyAuthorization {
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
                try authorizeRequest(&request)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                authorization?.apply(to: &request)
                let transport = try await urlSession.responsePreservingTransportError(for: request)
                try Task.checkCancellation()
                let response = transport.response as? HTTPURLResponse
                let data = transport.data
                let decoded: RPCResponse<Value>?
                do {
                    if let policyError = transport.error as? HTTPResponsePolicyError { throw policyError }
                    decoded = try data.flatMap {
                        try NativeRPCResponseDecoder.decode(RPCResponse<Value>.self, from: $0, expectedID: Self.requestID)
                    }
                } catch is HTTPResponsePolicyError {
                    try Task.checkCancellation()
                    if response?.statusCode == 401, let rejected = authorization {
                        await requestAuthorization.invalidate(afterUnauthorized: rejected)
                    }
                    try Task.checkCancellation()
                    throw EthereumRPCError.unknown
                }
                guard let response else {
                    failure = EthereumRPCError.unknown
                    break attempt
                }
                try Task.checkCancellation()
                if response.statusCode == 401, retryPolicy == .never {
                    if let rejected = authorization {
                        await requestAuthorization.invalidate(afterUnauthorized: rejected)
                        try Task.checkCancellation()
                    }
                    if let result = decoded?.result { return result }
                    if let error = decoded?.error {
                        throw Self.serverError(code: error.code, message: error.message, responseData: data)
                    }
                    throw EthereumRPCError.unknown
                }
                if response.statusCode == 401, let rejected = authorization {
                    guard requestAuthorization.reserveUnauthorizedRecovery() else {
                        await requestAuthorization.invalidate(afterUnauthorized: rejected)
                        try Task.checkCancellation()
                        throw EthereumRPCError.unknown
                    }
                    do {
                        let replacement = try await requestAuthorization.replacement(afterUnauthorized: rejected)
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

    public static func estimateGasTransactionObject(for transaction: Transaction) -> [String: Any] {
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
