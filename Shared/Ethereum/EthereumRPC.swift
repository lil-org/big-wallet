// ∅ 2026 lil org

import Foundation

struct EthereumFeeHistory: Decodable, Equatable {
    let baseFeePerGas: [String]
    let reward: [[String]]?
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

protocol EthereumFeeHistoryRPCClient {
    func fetchFeeHistory(
        rpcUrl: String,
        blockCount: UInt,
        rewardPercentiles: [Double],
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    )
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

enum EthereumRPCError: Error {
    case serverError(Int, String)
    case unknown
}

class EthereumRPC: EthereumFeeHistoryRPCClient {

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

    init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
    }

    func fetchFeeHistory(
        rpcUrl: String,
        blockCount: UInt,
        rewardPercentiles: [Double],
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        request(
            method: "eth_feeHistory",
            params: [String.hex(blockCount, withPrefix: true), "latest", rewardPercentiles],
            rpcUrl: rpcUrl,
            retryPolicy: .transientFailures,
            completion: completion
        )
    }
    
    func fetchGasPrice(rpcUrl: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_gasPrice", params: [], rpcUrl: rpcUrl, retryPolicy: .transientFailures, completion: completion)
    }
    
    func getBalance(rpcUrl: String, for address: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_getBalance", params: [address, "pending"], rpcUrl: rpcUrl, retryPolicy: .transientFailures, completion: completion)
    }
    
    func fetchNonce(rpcUrl: String, for address: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_getTransactionCount", params: [address, "pending"], rpcUrl: rpcUrl, retryPolicy: .transientFailures, completion: completion)
    }
    
    func estimateGas(rpcUrl: String, transaction: Transaction, completion: @escaping (Result<String, Error>) -> Void) {
        let dict = Self.estimateGasTransactionObject(for: transaction)
        request(method: "eth_estimateGas", params: [dict], rpcUrl: rpcUrl, retryPolicy: .transientFailures, completion: completion)
    }

    static func estimateGasTransactionObject(for transaction: Transaction) -> [String: Any] {
        var dict: [String: Any] = ["from": transaction.from, "data": transaction.data]
        if !transaction.to.isEmpty { dict["to"] = transaction.to }
        if let gasPrice = transaction.gasPrice { dict["gasPrice"] = gasPrice }
        if let gas = transaction.gas { dict["gas"] = gas }
        if let value = transaction.value, value != String.hexPrefix, value != "0" { dict["value"] = value }
        return dict
    }
    
    func sendRawTransaction(rpcUrl: String, signedTxData: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(method: "eth_sendRawTransaction", params: [signedTxData], rpcUrl: rpcUrl, retryPolicy: .never, completion: completion)
    }
    
    private func request<ResultValue: Decodable>(
        method: String,
        params: [Any],
        rpcUrl: String,
        retryCount: Int = 0,
        retryPolicy: RetryPolicy,
        completion: @escaping (Result<ResultValue, Error>) -> Void
    ) {
        guard let url = URL(string: rpcUrl), url.scheme != nil else {
            completion(.failure(EthereumRPCError.unknown))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: dict)
        } catch {
            completion(.failure(error))
            return
        }
        
        let task = urlSession.dataTask(with: request) { data, response, error in
            func retryRequest(failure: Error = EthereumRPCError.unknown) {
                self.retry(
                    method: method,
                    params: params,
                    rpcUrl: rpcUrl,
                    retryCount: retryCount,
                    retryPolicy: retryPolicy,
                    failure: failure,
                    completion: completion
                )
            }

            if error != nil {
                retryRequest()
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                retryRequest()
                return
            }

            let rpcResponse = data.flatMap {
                try? JSONDecoder().decode(RPCResponse<ResultValue>.self, from: $0)
            }

            if let result = rpcResponse?.result {
                completion(.success(result))
                return
            } else if let error = rpcResponse?.error {
                let rpcError = EthereumRPCError.serverError(error.code, error.message)
                if Self.isTerminalRequestError(code: error.code) {
                    completion(.failure(rpcError))
                } else if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode) {
                    retryRequest(failure: rpcError)
                } else {
                    completion(.failure(rpcError))
                }
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode) {
                    retryRequest()
                } else {
                    completion(.failure(EthereumRPCError.unknown))
                }
                return
            }

            retryRequest()
        }
        
        task.resume()
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
        rpcUrl: String,
        retryCount: Int,
        retryPolicy: RetryPolicy,
        failure: Error,
        completion: @escaping (Result<ResultValue, Error>) -> Void
    ) {
        guard retryPolicy.allowsRetries, retryCount <= 3 else {
            completion(.failure(failure))
            return
        }

        queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
            self.request(
                method: method,
                params: params,
                rpcUrl: rpcUrl,
                retryCount: retryCount + 1,
                retryPolicy: retryPolicy,
                completion: completion
            )
        }
    }
    
}
