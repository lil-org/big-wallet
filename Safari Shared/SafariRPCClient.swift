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
              expectedResponseID: Int,
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
                let response = try await self.performSend(
                    endpoint: endpoint,
                    body: body,
                    authorization: authorization,
                    didRetryUnauthorized: false,
                    expectedResponseID: expectedResponseID
                )
                completion(response)
            } catch {
                completion(nil)
            }
        }
    }

    private func performSend(endpoint: EthereumRPCEndpoint,
                             body: Data,
                             authorization: AlchemyAuthorization?,
                             didRetryUnauthorized: Bool,
                             expectedResponseID: Int) async throws
        -> [String: Any]? {
        let url = endpoint.url
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        authorization?.apply(to: &request)

        let redirectDelegate = NoRedirectSessionDelegate()
        let (data, response) = try await urlSession.data(
            for: request,
            delegate: redirectDelegate
        )
        guard !redirectDelegate.didRejectRedirect else { return nil }
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 401,
           let authorization {
            guard !didRetryUnauthorized,
                  Self.allowsUnauthorizedReplay(for: body) else {
                await self.authorizationProvider.invalidateAuthorization(
                    afterUnauthorized: authorization,
                    for: url
                )
                return Self.responseDictionary(
                    from: data,
                    expectedResponseID: expectedResponseID
                )
            }

            guard let replacement = try await self.authorizationProvider
                .replacementAuthorization(
                    afterUnauthorized: authorization,
                    for: url
                ) else {
                return nil
            }
            return try await self.performSend(
                endpoint: endpoint,
                body: body,
                authorization: replacement,
                didRetryUnauthorized: true,
                expectedResponseID: expectedResponseID
            )
        }

        return Self.responseDictionary(
            from: data,
            expectedResponseID: expectedResponseID
        )
    }

    private static func responseDictionary(
        from data: Data,
        expectedResponseID: Int
    ) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if var response = object as? [String: Any] {
            if let responseID = response["id"],
               !(responseID is NSNull) {
                guard responseIDMatches(
                    responseID,
                    expectedResponseID: expectedResponseID
                ) else {
                    return nil
                }
            }
            response["id"] = expectedResponseID
            return response
        }

        guard let batch = object as? [Any] else {
            return nil
        }
        let matches = batch.compactMap { value -> [String: Any]? in
            guard let response = value as? [String: Any],
                  responseIDMatches(
                      response["id"],
                      expectedResponseID: expectedResponseID
                  ) else {
                return nil
            }
            return response
        }
        guard matches.count == 1 else { return nil }
        var match = matches[0]
        match["id"] = expectedResponseID
        return match
    }

    private static func responseIDMatches(
        _ value: Any?,
        expectedResponseID: Int
    ) -> Bool {
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number as? Int == expectedResponseID
        }
        if let string = value as? String {
            return Int(string) == expectedResponseID
        }
        return false
    }

    private static func allowsUnauthorizedReplay(for body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return false
        }

        if let request = object as? [String: Any] {
            return Self.isReplaySafeRequest(request)
        }

        guard let batch = object as? [[String: Any]], !batch.isEmpty else {
            return false
        }
        return batch.allSatisfy { Self.isReplaySafeRequest($0) }
    }

    private static func isReplaySafeRequest(
        _ request: [String: Any]
    ) -> Bool {
        guard let method = request["method"] as? String else {
            return false
        }
        return Self.isReplaySafeReadMethod(method)
    }

    private static func isReplaySafeReadMethod(_ method: String) -> Bool {
        return Self.replaySafeMethods.contains(method)
            || Self.replaySafeMethodPrefixes.contains {
                method.hasPrefix($0)
            }
    }

}
