// ∅ 2026 lil org

import Foundation
#if canImport(XCTest) && canImport(Big_Wallet)
@testable import Big_Wallet
#endif

final class SafariRPCClient {

    private static let replaySafeMethods: Set<String> = [
        "eth_accounts",
        "eth_baseFee",
        "eth_blobBaseFee",
        "eth_blockNumber",
        "eth_call",
        "eth_callBundle",
        "eth_callMany",
        "eth_chainId",
        "eth_createAccessList",
        "eth_estimateGas",
        "eth_estimateUserOperationGas",
        "eth_feeHistory",
        "eth_fillTransaction",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_pendingTransactions",
        "eth_protocolVersion",
        "eth_supportedEntryPoints",
        "eth_syncing",
        "net_listening",
        "net_peerCount",
        "net_version",
        "parity_pendingTransactions",
        "rundler_maxPriorityFeePerGas",
        "txpool_content",
        "txpool_contentFrom",
        "txpool_inspect",
        "txpool_status",
        "web3_clientVersion",
        "web3_sha3",
    ]
    private static let replaySafeMethodPrefixes = [
        "alchemy_get",
        "alchemy_simulate",
        "debug_trace",
        "eth_get",
        "eth_simulate",
        "trace_",
    ]

    private let urlSession: URLSession
    private let authorizationProvider: AlchemyAuthorizationProviding

    init(urlSession: URLSession = .shared,
         authorizationProvider: AlchemyAuthorizationProviding = AlchemyJWTProvider.shared) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
    }

    func send(endpoint: EthereumRPCEndpoint,
              body: Data,
              completion: @escaping ([String: Any]?) -> Void) {
        Task {
            do {
                let authorization: AlchemyAuthorization?
                if endpoint.allowsAlchemyAuthorization {
                    authorization = try await self.authorizationProvider.authorization(
                        for: endpoint.url
                    )
                } else {
                    authorization = nil
                }
                self.performSend(
                    endpoint: endpoint,
                    body: body,
                    authorization: authorization,
                    didRetryUnauthorized: false,
                    completion: completion
                )
            } catch {
                completion(nil)
            }
        }
    }

    private func performSend(endpoint: EthereumRPCEndpoint,
                             body: Data,
                             authorization: AlchemyAuthorization?,
                             didRetryUnauthorized: Bool,
                             completion: @escaping ([String: Any]?) -> Void) {
        let url = endpoint.url
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        authorization?.apply(to: &request)

        urlSession.dataTask(with: request) { data, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 401,
               let authorization {
                guard !didRetryUnauthorized,
                      Self.allowsUnauthorizedReplay(for: body) else {
                    Task {
                        await self.authorizationProvider.invalidateAuthorization(
                            afterUnauthorized: authorization,
                            for: url
                        )
                        completion(nil)
                    }
                    return
                }
                Task {
                    do {
                        guard let replacement = try await self.authorizationProvider
                            .replacementAuthorization(
                                afterUnauthorized: authorization,
                                for: url
                            ) else {
                            completion(nil)
                            return
                        }
                        self.performSend(
                            endpoint: endpoint,
                            body: body,
                            authorization: replacement,
                            didRetryUnauthorized: true,
                            completion: completion
                        )
                    } catch {
                        completion(nil)
                    }
                }
                return
            }

            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let response = object as? [String: Any] else {
                completion(nil)
                return
            }
            completion(response)
        }.resume()
    }

    private static func allowsUnauthorizedReplay(for body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return false
        }

        if let request = object as? [String: Any] {
            guard let method = request["method"] as? String else {
                return false
            }
            return method == "eth_sendRawTransaction"
                || Self.isReplaySafeReadMethod(method)
        }

        guard let batch = object as? [[String: Any]], !batch.isEmpty else {
            return false
        }
        return batch.allSatisfy { request in
            guard let method = request["method"] as? String else {
                return false
            }
            return Self.isReplaySafeReadMethod(method)
        }
    }

    private static func isReplaySafeReadMethod(_ method: String) -> Bool {
        return Self.replaySafeMethods.contains(method)
            || Self.replaySafeMethodPrefixes.contains {
                method.hasPrefix($0)
            }
    }

}
