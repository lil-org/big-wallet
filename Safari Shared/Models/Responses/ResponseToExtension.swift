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

    enum Result {
        case string(String)
        case strings([String])
        case solanaPublicKey(String)
        case null

        var json: Any {
            switch self {
            case .string(let value): return value
            case .strings(let values): return values
            case .solanaPublicKey(let publicKey): return ["publicKey": publicKey]
            case .null: return NSNull()
            }
        }

        init?(json: Any) {
            if json is NSNull { self = .null }
            else if let value = json as? String { self = .string(value) }
            else if let values = json as? [String] { self = .strings(values) }
            else if let value = json as? [String: Any],
                    Set(value.keys) == ["publicKey"],
                    let publicKey = value["publicKey"] as? String {
                self = .solanaPublicKey(publicKey)
            } else { return nil }
        }
    }

    enum AccountUpdate: Equatable {
        case ethereum(address: String, chainId: String)
        case solana(publicKey: String)
        case disconnectEthereum
        case disconnectSolana

        var provider: InpageProvider {
            switch self {
            case .ethereum, .disconnectEthereum: return .ethereum
            case .solana, .disconnectSolana: return .solana
            }
        }

        var json: Any {
            switch self {
            case .ethereum(let address, let chainId):
                return ["address": address, "chainId": chainId]
            case .solana(let publicKey): return ["publicKey": publicKey]
            case .disconnectEthereum, .disconnectSolana: return NSNull()
            }
        }
    }

    enum ConfigurationMutation: Equatable {
        case accounts([AccountUpdate])
        case ethereumChain(String)
        case revokeSolana(String)

        var json: [String: Any] {
            switch self {
            case .accounts(let updates):
                var values = [String: Any]()
                for update in updates { values[update.provider.rawValue] = update.json }
                return ["kind": "accounts", "updates": values]
            case .ethereumChain(let chainId):
                return ["kind": "ethereumChain", "chainId": chainId]
            case .revokeSolana(let publicKey):
                return ["kind": "revokeSolana", "publicKey": publicKey]
            }
        }

        init?(json: [String: Any]) {
            switch json["kind"] as? String {
            case "accounts":
                guard Set(json.keys) == ["kind", "updates"],
                      let values = json["updates"] as? [String: Any],
                      Set(values.keys).isSubset(of: ["ethereum", "solana"]) else { return nil }
                var updates = [AccountUpdate]()
                if let ethereum = values["ethereum"] {
                    if ethereum is NSNull { updates.append(.disconnectEthereum) }
                    else {
                        guard let value = ethereum as? [String: Any],
                              Set(value.keys) == ["address", "chainId"],
                              let address = value["address"] as? String,
                              let chainId = value["chainId"] as? String,
                              Self.isCanonicalChainID(chainId) else { return nil }
                        updates.append(.ethereum(address: address, chainId: chainId))
                    }
                }
                if let solana = values["solana"] {
                    if solana is NSNull { updates.append(.disconnectSolana) }
                    else {
                        guard let value = solana as? [String: Any],
                              Set(value.keys) == ["publicKey"],
                              let publicKey = value["publicKey"] as? String,
                              WalletCrypto.base58Decode(string: publicKey)?.count == 32 else { return nil }
                        updates.append(.solana(publicKey: publicKey))
                    }
                }
                self = .accounts(updates)
            case "ethereumChain":
                guard Set(json.keys) == ["kind", "chainId"],
                      let chainId = json["chainId"] as? String,
                      Self.isCanonicalChainID(chainId) else { return nil }
                self = .ethereumChain(chainId)
            case "revokeSolana":
                guard Set(json.keys) == ["kind", "publicKey"],
                      let publicKey = json["publicKey"] as? String,
                      !publicKey.isEmpty else { return nil }
                self = .revokeSolana(publicKey)
            default: return nil
            }
        }

        private static func isCanonicalChainID(_ value: String) -> Bool {
            guard let number = Int(hexString: value), number > 0 else { return false }
            return String.hex(number, withPrefix: true) == value
        }
    }

    enum Payload {
        case result(Result)
        case error(ProviderResponseError)
    }

    let id: Int
    let name: String
    let provider: InpageProvider
    let payload: Payload
    let mutation: ConfigurationMutation?
    private(set) var approvalCommitted = false
    let authorizationFailure: Bool

    init(
        for request: SafariRequest,
        payload: Payload,
        mutation: ConfigurationMutation? = nil
    ) {
        id = request.id
        name = request.name
        provider = request.provider == .unknown ? .multiple : request.provider
        self.payload = payload
        if case .error(let error) = payload,
           case .unauthorizedPublicKey(let publicKey) = error.context,
           provider == .solana, error.code == 4100 {
            self.mutation = .revokeSolana(publicKey)
            authorizationFailure = true
        } else {
            self.mutation = mutation
            authorizationFailure = false
        }
    }

    func markingApprovalCommitted() -> ResponseToExtension {
        var response = self
        response.approvalCommitted = true
        return response
    }

    var addsEthereumChain: Bool {
        guard name == SafariRequest.Ethereum.Method.addEthereumChain.rawValue,
              provider == .ethereum,
              case .result = payload,
              case .ethereumChain = mutation else { return false }
        return true
    }

    var json: [String: Any] {
        var json: [String: Any] = [
            "id": id, "name": name, "provider": provider.rawValue,
            "approvalCommitted": approvalCommitted,
            "mutation": mutation.map { $0.json as Any } ?? NSNull(),
        ]
        switch payload {
        case .result(let result):
            json["kind"] = "result"
            json["result"] = result.json
        case .error(let error):
            json["kind"] = "error"
            json["authorizationFailure"] = authorizationFailure
            var value: [String: Any] = [
                "code": error.code ?? ProviderResponseError.internalErrorCode,
                "message": error.message,
            ]
            switch error.context {
            case .dataJSON(let raw):
                value["data"] = raw.data(using: .utf8).flatMap {
                    try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
                }
            case .transactionHash(let hash): value["data"] = ["transactionHash": hash]
            case .transactionSignature(let signature): value["data"] = ["signature": signature]
            case .unauthorizedPublicKey, nil: break
            }
            json["error"] = value
        }
        return json
    }

    init?(json: [String: Any]) {
        let common: Set<String> = ["id", "name", "provider", "kind", "approvalCommitted", "mutation"]
        guard let id = Self.integer(json["id"]),
              (-9_007_199_254_740_991...9_007_199_254_740_991).contains(id),
              let name = json["name"] as? String,
              let rawProvider = json["provider"] as? String,
              let provider = InpageProvider(rawValue: rawProvider), provider != .unknown,
              (provider == .multiple) == (name == "switchAccount"),
              let committed = Self.boolean(json["approvalCommitted"]),
              let rawMutation = json["mutation"] else { return nil }
        let mutation: ConfigurationMutation?
        if rawMutation is NSNull { mutation = nil }
        else {
            guard let raw = rawMutation as? [String: Any],
                  let decoded = ConfigurationMutation(json: raw) else { return nil }
            mutation = decoded
        }
        let payload: Payload
        let authorizationFailure: Bool
        switch json["kind"] as? String {
        case "result":
            guard Set(json.keys) == common.union(["result"]),
                  let value = json["result"], let result = Result(json: value) else { return nil }
            if case .revokeSolana = mutation { return nil }
            if provider == .multiple {
                guard case .null = result, case .accounts = mutation else { return nil }
            }
            payload = .result(result)
            authorizationFailure = false
        case "error":
            guard Set(json.keys) == common.union(["error", "authorizationFailure"]),
                  let error = json["error"] as? [String: Any],
                  Set(error.keys).isSubset(of: ["code", "message", "data"]),
                  let code = Self.integer(error["code"]),
                  let message = error["message"] as? String,
                  provider != .multiple || !message.isEmpty,
                  let failure = Self.boolean(json["authorizationFailure"]) else { return nil }
            if let mutation {
                guard case .revokeSolana = mutation, provider == .solana,
                      code == 4100, failure else { return nil }
            }
            let context: ProviderResponseError.Context?
            if let data = error["data"] {
                guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed, .sortedKeys]),
                      let string = String(data: encoded, encoding: .utf8) else { return nil }
                context = .dataJSON(string)
            } else { context = nil }
            payload = .error(.init(message: message, code: code, context: context))
            authorizationFailure = failure
        default: return nil
        }
        if case .accounts(let updates) = mutation {
            guard provider == .multiple || updates.allSatisfy({ $0.provider == provider }) else { return nil }
        }
        if case .ethereumChain = mutation, provider != .ethereum { return nil }
        self.id = id
        self.name = name
        self.provider = provider
        self.payload = payload
        self.mutation = mutation
        self.approvalCommitted = committed
        self.authorizationFailure = authorizationFailure
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber, let integer = value as? Int,
              number.doubleValue == Double(integer) else { return nil }
        return integer
    }
}
