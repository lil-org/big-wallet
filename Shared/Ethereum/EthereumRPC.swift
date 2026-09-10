// ∅ 2026 lil org

import Foundation

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

struct EthereumFeeHistory: Decodable, Equatable {
    let baseFeePerGas: [String]
    let reward: [[String]]?
}

struct EthereumLatestBlock: Decodable, Equatable {

    enum BaseFeeField: Equatable {
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

protocol EthereumFeeRPCClient: AnyObject {
    func fetchChainID(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    )

    func fetchMaxPriorityFeePerGas(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func fetchLatestBlock(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumLatestBlock, Error>) -> Void
    )

    func fetchGasPrice(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    )
}

extension EthereumFeeRPCClient {

    func fetchChainID(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.failure(EthereumRPCError.serverError(
            -32_601,
            "eth_chainId is not implemented by this client"
        )))
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double],
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        fetchFeeHistory(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: "latest",
            rewardPercentiles: rewardPercentiles,
            cancellation: nil,
            completion: completion
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        fetchFeeHistory(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: "latest",
            rewardPercentiles: rewardPercentiles,
            cancellation: cancellation,
            completion: completion
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        completion(.failure(EthereumRPCError.serverError(
            -32_601,
            "eth_feeHistory is not implemented by this client"
        )))
    }

    func fetchMaxPriorityFeePerGas(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.failure(EthereumRPCError.serverError(
            -32_601,
            "eth_maxPriorityFeePerGas is not implemented by this client"
        )))
    }

    func fetchLatestBlock(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumLatestBlock, Error>) -> Void
    ) {
        completion(.failure(EthereumRPCError.serverError(
            -32_601,
            "eth_getBlockByNumber is not implemented by this client"
        )))
    }

    func fetchGasPrice(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        completion(.failure(EthereumRPCError.serverError(
            -32_601,
            "eth_gasPrice is not implemented by this client"
        )))
    }

}

protocol EthereumRPCClient: EthereumFeeRPCClient {

    func getBalance(
        endpoint: EthereumRPCEndpoint,
        for address: String,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func fetchNonce(
        endpoint: EthereumRPCEndpoint,
        for address: String,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func estimateGas(
        endpoint: EthereumRPCEndpoint,
        transaction: Transaction,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func sendRawTransaction(
        endpoint: EthereumRPCEndpoint,
        signedTxData: String,
        completion: @escaping (Result<String, Error>) -> Void
    )
}

final class EthereumRequestCancellation: @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var isCancelledStorage = false
    private var cancellationActions = [UUID: () -> Void]()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledStorage
    }

    func cancel() {
        cancel(performing: {})
    }

    @discardableResult
    func cancel(performing action: () -> Void) -> Bool {
        lock.lock()
        guard !isCancelledStorage else {
            lock.unlock()
            return false
        }
        isCancelledStorage = true
        let actions = Array(cancellationActions.values)
        cancellationActions.removeAll()
        action()
        lock.unlock()

        actions.forEach { $0() }
        return true
    }

    @discardableResult
    func register(
        identifier: UUID,
        cancellation: @escaping () -> Void
    ) -> Bool {
        lock.lock()
        if isCancelledStorage {
            lock.unlock()
            cancellation()
            return false
        }
        cancellationActions[identifier] = cancellation
        lock.unlock()
        return true
    }

    func finish(identifier: UUID) {
        lock.lock()
        cancellationActions.removeValue(forKey: identifier)
        lock.unlock()
    }

    @discardableResult
    func performIfActive(_ action: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelledStorage else { return false }
        action()
        return true
    }

    deinit {
        cancel()
    }

}

private struct RPCResponse<ResultValue: Decodable>: Decodable {
    let jsonrpc: String
    let result: ResultValue?
    let error: Error?
    
    struct Error: Decodable {
        let code: Int
        let message: String
    }
}

enum EthereumRPCError: Error, Equatable, Sendable {
    case serverError(Int, String, dataJSON: String? = nil)
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

final class NoRedirectSessionDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {

    private let lock = NSLock()
    private var rejectedRedirect = false

    var didRejectRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        rejectedRedirect = true
        lock.unlock()
        completionHandler(nil)
    }
}

class EthereumRPC: EthereumRPCClient {

    private enum RetryPolicy {
        case transientFailures
        case never

        var allowsRetries: Bool {
            switch self {
            case .transientFailures:
                return true
            case .never:
                return false
            }
        }

        func shouldRetry(statusCode: Int) -> Bool {
            switch self {
            case .transientFailures:
                return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
            case .never:
                return false
            }
        }
    }
    
    private let queue = DispatchQueue(label: "EthereumRPC")
    private let urlSession: URLSession
    private let authorizationProvider: AlchemyAuthorizationProviding

    init(urlSession: URLSession = URLSession(configuration: .default),
         authorizationProvider: AlchemyAuthorizationProviding = AlchemyJWTProvider.shared) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
    }

    func fetchChainID(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        request(
            method: "eth_chainId",
            params: [],
            endpoint: endpoint,
            cancellation: cancellation,
            retryPolicy: .transientFailures,
            completion: completion
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        fetchFeeHistory(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: "latest",
            rewardPercentiles: rewardPercentiles,
            cancellation: cancellation,
            completion: completion
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        request(
            method: "eth_feeHistory",
            params: [
                String.hex(blockCount, withPrefix: true),
                newestBlock,
                rewardPercentiles
            ],
            endpoint: endpoint,
            cancellation: cancellation,
            retryPolicy: .transientFailures,
            completion: completion
        )
    }

    func fetchMaxPriorityFeePerGas(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        request(
            method: "eth_maxPriorityFeePerGas",
            params: [],
            endpoint: endpoint,
            cancellation: cancellation,
            retryPolicy: .transientFailures,
            completion: completion
        )
    }

    func fetchLatestBlock(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Result<EthereumLatestBlock, Error>) -> Void
    ) {
        request(
            method: "eth_getBlockByNumber",
            params: ["latest", false],
            endpoint: endpoint,
            cancellation: cancellation,
            retryPolicy: .transientFailures,
            completion: completion
        )
    }
    
    func fetchGasPrice(endpoint: EthereumRPCEndpoint,
                       cancellation: EthereumRequestCancellation? = nil,
                       completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_gasPrice",
                params: [],
                endpoint: endpoint,
                cancellation: cancellation,
                retryPolicy: .transientFailures,
                completion: completion)
    }
    
    func getBalance(endpoint: EthereumRPCEndpoint,
                    for address: String,
                    completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_getBalance",
                params: [address, "pending"],
                endpoint: endpoint,
                retryPolicy: .transientFailures,
                completion: completion)
    }
    
    func fetchNonce(endpoint: EthereumRPCEndpoint,
                    for address: String,
                    cancellation: EthereumRequestCancellation? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_getTransactionCount",
                params: [address, "pending"],
                endpoint: endpoint,
                cancellation: cancellation,
                retryPolicy: .transientFailures,
                completion: completion)
    }
    
    func estimateGas(endpoint: EthereumRPCEndpoint,
                     transaction: Transaction,
                     cancellation: EthereumRequestCancellation? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let dict = Self.estimateGasTransactionObject(for: transaction)
        request(method: "eth_estimateGas",
                params: [dict],
                endpoint: endpoint,
                cancellation: cancellation,
                retryPolicy: .transientFailures,
                completion: completion)
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
    
    func sendRawTransaction(endpoint: EthereumRPCEndpoint,
                            signedTxData: String,
                            completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_sendRawTransaction",
                params: [signedTxData],
                endpoint: endpoint,
                retryPolicy: .never,
                completion: completion)
    }
    
    private func request<ResultValue: Decodable>(
        method: String,
        params: [Any],
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation? = nil,
        retryCount: Int = 0,
        retryPolicy: RetryPolicy,
        didAttemptAuthorizationRecovery: Bool = false,
        completion: @escaping (Result<ResultValue, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else { return }
        let url = endpoint.url
        guard url.scheme != nil else {
            complete(
                .failure(EthereumRPCError.unknown),
                cancellation: cancellation,
                completion: completion
            )
            return
        }

        let dict: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let body: Data

        do {
            body = try JSONSerialization.data(withJSONObject: dict)
        } catch {
            complete(
                .failure(error),
                cancellation: cancellation,
                completion: completion
            )
            return
        }

        performCancellableTask(cancellation: cancellation) {
            guard cancellation?.isCancelled != true else { return }
            do {
                let authorization: AlchemyAuthorization?
                if endpoint.allowsAlchemyAuthorization {
                    authorization = try await self.authorizationProvider.authorization(for: url)
                } else {
                    authorization = nil
                }
                guard cancellation?.isCancelled != true else { return }
                guard !endpoint.allowsAlchemyAuthorization || authorization != nil else {
                    self.retry(
                        method: method,
                        params: params,
                        endpoint: endpoint,
                        cancellation: cancellation,
                        retryCount: retryCount,
                        retryPolicy: retryPolicy,
                        didAttemptAuthorizationRecovery:
                            didAttemptAuthorizationRecovery,
                        failure: EthereumRPCError.unknown,
                        completion: completion
                    )
                    return
                }
                self.performRequest(
                    method: method,
                    params: params,
                    endpoint: endpoint,
                    body: body,
                    cancellation: cancellation,
                    retryCount: retryCount,
                    retryPolicy: retryPolicy,
                    didAttemptAuthorizationRecovery:
                        didAttemptAuthorizationRecovery,
                    authorization: authorization,
                    completion: completion
                )
            } catch {
                self.retry(
                    method: method,
                    params: params,
                    endpoint: endpoint,
                    cancellation: cancellation,
                    retryCount: retryCount,
                    retryPolicy: retryPolicy,
                    didAttemptAuthorizationRecovery:
                        didAttemptAuthorizationRecovery,
                    failure: error,
                    completion: completion
                )
            }
        }
    }

    private func performRequest<ResultValue: Decodable>(
        method: String,
        params: [Any],
        endpoint: EthereumRPCEndpoint,
        body: Data,
        cancellation: EthereumRequestCancellation?,
        retryCount: Int,
        retryPolicy: RetryPolicy,
        didAttemptAuthorizationRecovery: Bool,
        authorization: AlchemyAuthorization?,
        completion: @escaping (Result<ResultValue, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else { return }
        let url = endpoint.url
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        authorization?.apply(to: &request)

        let taskIdentifier = UUID()
        let taskBox = WeakURLSessionTaskBox()
        let redirectDelegate = NoRedirectSessionDelegate()
        let task = urlSession.dataTask(with: request) { data, response, error in
            defer {
                cancellation?.finish(identifier: taskIdentifier)
            }
            guard cancellation?.isCancelled != true else { return }

            if redirectDelegate.didRejectRedirect {
                self.complete(
                    .failure(EthereumRPCError.unknown),
                    cancellation: cancellation,
                    completion: completion
                )
                return
            }

            func retryRequest(
                failure: Error = EthereumRPCError.unknown,
                afterAuthorizationRecovery: Bool = false
            ) {
                self.retry(
                    method: method,
                    params: params,
                    endpoint: endpoint,
                    cancellation: cancellation,
                    retryCount: retryCount,
                    retryPolicy: retryPolicy,
                    didAttemptAuthorizationRecovery:
                        didAttemptAuthorizationRecovery
                            || afterAuthorizationRecovery,
                    failure: failure,
                    completion: completion
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                retryRequest()
                return
            }

            if httpResponse.statusCode == 401,
               case .never = retryPolicy {
                let rpcResponse = data.flatMap {
                    try? JSONDecoder().decode(
                        RPCResponse<ResultValue>.self,
                        from: $0
                    )
                }
                let firstResponseResult: Result<ResultValue, Swift.Error>
                if let result = rpcResponse?.result {
                    firstResponseResult = .success(result)
                } else if let error = rpcResponse?.error {
                    firstResponseResult = .failure(Self.serverError(
                        code: error.code,
                        message: error.message,
                        responseData: data
                    ))
                } else {
                    firstResponseResult = .failure(EthereumRPCError.unknown)
                }

                guard let authorization else {
                    self.complete(
                        firstResponseResult,
                        cancellation: cancellation,
                        completion: completion
                    )
                    return
                }
                self.performCancellableTask(cancellation: cancellation) {
                    await self.authorizationProvider.invalidateAuthorization(
                        afterUnauthorized: authorization,
                        for: url
                    )
                    self.complete(
                        firstResponseResult,
                        cancellation: cancellation,
                        completion: completion
                    )
                }
                return
            }

            if httpResponse.statusCode == 401,
               let authorization {
                guard !didAttemptAuthorizationRecovery else {
                    self.performCancellableTask(
                        cancellation: cancellation
                    ) {
                        guard cancellation?.isCancelled != true else { return }
                        await self.authorizationProvider.invalidateAuthorization(
                            afterUnauthorized: authorization,
                            for: url
                        )
                        self.complete(
                            .failure(EthereumRPCError.unknown),
                            cancellation: cancellation,
                            completion: completion
                        )
                    }
                    return
                }
                self.performCancellableTask(
                    cancellation: cancellation
                ) {
                    guard cancellation?.isCancelled != true else { return }
                    do {
                        guard let replacement = try await self.authorizationProvider
                            .replacementAuthorization(
                                afterUnauthorized: authorization,
                                for: url
                            ) else {
                            retryRequest(afterAuthorizationRecovery: true)
                            return
                        }
                        guard cancellation?.isCancelled != true else { return }
                        self.performRequest(
                            method: method,
                            params: params,
                            endpoint: endpoint,
                            body: body,
                            cancellation: cancellation,
                            retryCount: retryCount,
                            retryPolicy: retryPolicy,
                            didAttemptAuthorizationRecovery: true,
                            authorization: replacement,
                            completion: completion
                        )
                    } catch {
                        retryRequest(
                            failure: error,
                            afterAuthorizationRecovery: true
                        )
                    }
                }
                return
            }

            if error != nil {
                retryRequest()
                return
            }

            let rpcResponse = data.flatMap {
                try? JSONDecoder().decode(RPCResponse<ResultValue>.self, from: $0)
            }

            if let result = rpcResponse?.result {
                self.complete(
                    .success(result),
                    cancellation: cancellation,
                    completion: completion
                )
                return
            } else if let error = rpcResponse?.error {
                let rpcError = Self.serverError(
                    code: error.code,
                    message: error.message,
                    responseData: data
                )
                if Self.isTerminalRequestError(code: error.code) {
                    self.complete(
                        .failure(rpcError),
                        cancellation: cancellation,
                        completion: completion
                    )
                } else if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode) {
                    retryRequest(failure: rpcError)
                } else {
                    self.complete(
                        .failure(rpcError),
                        cancellation: cancellation,
                        completion: completion
                    )
                }
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode) {
                    retryRequest()
                } else {
                    self.complete(
                        .failure(EthereumRPCError.unknown),
                        cancellation: cancellation,
                        completion: completion
                    )
                }
                return
            }

            retryRequest()
        }

        task.delegate = redirectDelegate
        taskBox.task = task
        guard cancellation?.register(
            identifier: taskIdentifier,
            cancellation: {
                taskBox.task?.cancel()
            }
        ) != false else {
            return
        }
        task.resume()
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

    private func retry<ResultValue: Decodable>(
        method: String,
        params: [Any],
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        retryCount: Int,
        retryPolicy: RetryPolicy,
        didAttemptAuthorizationRecovery: Bool,
        failure: Error,
        completion: @escaping (Result<ResultValue, Error>) -> Void
    ) {
        guard cancellation?.isCancelled != true else { return }
        guard retryPolicy.allowsRetries, retryCount <= 3 else {
            complete(
                .failure(failure),
                cancellation: cancellation,
                completion: completion
            )
            return
        }

        queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
            guard cancellation?.isCancelled != true else { return }
            self.request(
                method: method,
                params: params,
                endpoint: endpoint,
                cancellation: cancellation,
                retryCount: retryCount + 1,
                retryPolicy: retryPolicy,
                didAttemptAuthorizationRecovery:
                    didAttemptAuthorizationRecovery,
                completion: completion
            )
        }
    }

    private func complete<ResultValue>(
        _ result: Result<ResultValue, Error>,
        cancellation: EthereumRequestCancellation?,
        completion: (Result<ResultValue, Error>) -> Void
    ) {
        guard let cancellation else {
            completion(result)
            return
        }
        cancellation.performIfActive {
            completion(result)
        }
    }

    private func performCancellableTask(
        cancellation: EthereumRequestCancellation?,
        operation: @escaping () async -> Void
    ) {
        guard let cancellation else {
            Task {
                await operation()
            }
            return
        }

        let identifier = UUID()
        let taskBox = SwiftTaskCancellationBox()
        guard cancellation.register(
            identifier: identifier,
            cancellation: {
                taskBox.cancel()
            }
        ) else {
            return
        }

        let task = Task {
            defer {
                taskBox.finish()
                cancellation.finish(identifier: identifier)
            }
            guard !Task.isCancelled,
                  !cancellation.isCancelled else {
                return
            }
            await operation()
        }
        taskBox.set(task)
    }
    
}

private final class WeakURLSessionTaskBox {

    weak var task: URLSessionTask?

}

private final class SwiftTaskCancellationBox: @unchecked Sendable {

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false
    private var isFinished = false

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
        } else if isFinished {
            lock.unlock()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    func finish() {
        lock.lock()
        isFinished = true
        task = nil
        lock.unlock()
    }

}
