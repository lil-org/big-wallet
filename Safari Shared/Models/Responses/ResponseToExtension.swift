// ∅ 2026 lil org

import Foundation

struct ProviderResponseError: Equatable {

    static let userRejectedCode = 4001
    static let internalErrorCode = -32_603
    static let transactionSubmissionUnknownCode = internalErrorCode

    enum Context: Equatable {
        case dataJSON(String)
        case transactionHash(String)
        case unauthorizedPublicKey(String)
        case transactionSignature(String)
    }

    let message: String
    let code: Int?
    let context: Context?

    init(
        message: String,
        code: Int? = nil,
        context: Context? = nil
    ) {
        self.message = message
        self.code = code
        self.context = context
    }

    // Dapps observe a request expiring and a live rejection as the same event, so every path
    // reporting either uses the same message-code pair. 4001 is the EIP-1193 user-rejected code.
    static var userRejected: ProviderResponseError {
        return ProviderResponseError(message: Strings.canceled, code: userRejectedCode)
    }

    static var internalError: ProviderResponseError {
        return ProviderResponseError(message: Strings.somethingWentWrong, code: internalErrorCode)
    }

    static var privateBrowsingUnsupported: ProviderResponseError {
        return ProviderResponseError(
            message: Strings.privateBrowsingUnsupported,
            code: 4200
        )
    }

}

struct ResponseToExtension {
    
    enum ConfigurationMutation: Equatable {
        case storesConfiguration
        case removesSolanaAuthorization(publicKey: String)
        case addsEthereumChain(chainId: String)

        static func classify(_ response: [String: Any]) -> ConfigurationMutation? {
            if response["name"] as? String ==
                SafariRequest.Ethereum.Method.addEthereumChain.rawValue,
               response["provider"] as? String == InpageProvider.ethereum.rawValue,
               let chainId = response["chainId"] as? String,
               response["error"] == nil {
                return .addsEthereumChain(chainId: chainId)
            }
            if response["errorCode"] as? Int == 4100,
               response["provider"] as? String == InpageProvider.solana.rawValue,
               let publicKey = response["errorPublicKey"] as? String {
                return .removesSolanaAuthorization(publicKey: publicKey)
            }
            if response["configurationToStore"] != nil {
                return .storesConfiguration
            }
            return nil
        }
    }

    let id: Int
    let json: [String: Any]

    private init(id: Int, json: [String: Any]) {
        self.id = id
        self.json = json
    }

    func markingApprovalCommitted() -> ResponseToExtension {
        var json = json
        json[ExtensionBridge.approvalCommittedKey] = true
        return ResponseToExtension(id: id, json: json)
    }
    
    enum Body {
        case ethereum(Ethereum)
        case solana(Solana)
        case multiple(Multiple)
        
        var json: [String: Any] {
            let data: Data?
            let jsonEncoder = JSONEncoder()

            switch self {
            case .ethereum(let body):
                data = try? jsonEncoder.encode(body)
            case .solana(let body):
                data = try? jsonEncoder.encode(body)
            case .multiple(let body):
                let dict: [String: Any] = [
                    "bodies": body.bodies.map { $0.json },
                    "providersToDisconnect": body.providersToDisconnect.map { $0.rawValue },
                    "provider": provider.rawValue
                ]
                return dict
            }

            if let data = data, var dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                dict["provider"] = provider.rawValue
                return dict
            } else {
                return [:]
            }
        }
        
        var provider: InpageProvider {
            switch self {
            case .ethereum:
                return .ethereum
            case .solana:
                return .solana
            case .multiple:
                return .multiple
            }
        }
    }

    enum Payload {
        case body(Body)
        case error(ProviderResponseError)
    }

    init(
        for request: SafariRequest,
        payload: Payload? = nil
    ) {
        self.id = request.id
        var json: [String: Any] = [
            "id": request.id,
            "name": request.name
        ]

        switch payload {
        case .body(let body):
            let bodyJSON = body.json
            json.merge(bodyJSON) { current, _ in current }

            if request.body.value.responseUpdatesStoredConfiguration {
                if let bodies = bodyJSON["bodies"] {
                    json["configurationToStore"] = bodies
                } else {
                    json["configurationToStore"] = bodyJSON
                }
            }
        case .error(let error):
            json["error"] = error.message
            json["provider"] = request.provider.rawValue
            if let code = error.code {
                json["errorCode"] = code
            }
            switch error.context {
            case .dataJSON(let dataJSON):
                json["errorDataJSON"] = dataJSON
            case .transactionHash(let transactionHash):
                if let data = try? JSONSerialization.data(
                    withJSONObject: ["transactionHash": transactionHash],
                    options: [.sortedKeys]
                ) {
                    json["errorDataJSON"] = String(data: data, encoding: .utf8)
                }
            case .unauthorizedPublicKey(let publicKey):
                json["errorPublicKey"] = publicKey
            case .transactionSignature(let signature):
                json["errorSignature"] = signature
            case nil:
                break
            }
        case nil:
            break
        }

        self.json = json
    }
    
}
