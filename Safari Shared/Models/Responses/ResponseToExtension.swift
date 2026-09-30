// ∅ 2026 lil org

import Foundation

struct ProviderResponseError: Equatable, Sendable {

    static let userRejectedCode = 4001
    static let internalErrorCode = -32_603
    static let transactionSubmissionUnknownCode = internalErrorCode

    enum Context: Equatable, Sendable {
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

    static var approvalInterrupted: ProviderResponseError {
        ProviderResponseError(message: Strings.approvalInterrupted, code: internalErrorCode)
    }

    static var privateBrowsingUnsupported: ProviderResponseError {
        return ProviderResponseError(
            message: Strings.privateBrowsingUnsupported,
            code: 4200
        )
    }

}

struct ResponseToExtension: Sendable {

    enum Result: Sendable {
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
                    let publicKey = value["publicKey"] as? String {
                self = .solanaPublicKey(publicKey)
            } else { return nil }
        }
    }

    enum AccountUpdate: Equatable, Sendable {
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

    }

    enum ConfigurationMutation: Equatable, Sendable {
        case accounts([AccountUpdate])
        case ethereumChain(String)
        case revokeSolana(String)
    }

    enum Payload: Sendable {
        case result(Result)
        case error(ProviderResponseError)
    }

    let id: Int
    let name: String
    let provider: InpageProvider
    let payload: Payload
    let mutation: ConfigurationMutation?
    let approvedAccounts: [WalletAccountDescriptor]
    private(set) var approvalCommitted = false
    let authorizationFailure: Bool

    init(
        for request: SafariRequest,
        payload: Payload,
        mutation: ConfigurationMutation? = nil,
        approvedAccounts: [WalletAccountDescriptor] = []
    ) {
        id = request.id
        name = request.name
        provider = request.provider == .unknown ? .multiple : request.provider
        self.payload = payload
        self.approvedAccounts = approvedAccounts
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
              case .result = payload else { return false }
        return true
    }

    var json: [String: Any] {
        var json: [String: Any] = [
            "id": id, "name": name, "provider": provider.rawValue,
            "approvalCommitted": approvalCommitted,
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
        guard let wire = WireProtocol.NativeResponse(json: json),
              let id = wire.json["id"] as? Int,
              let name = wire.json["name"] as? String,
              let rawProvider = wire.json["provider"] as? String,
              let provider = InpageProvider(rawValue: rawProvider),
              let committed = wire.json["approvalCommitted"] as? Bool else { return nil }
        let json = wire.json
        let payload: Payload
        let authorizationFailure: Bool
        switch json["kind"] as? String {
        case "result":
            guard let value = json["result"], let result = Result(json: value) else { return nil }
            payload = .result(result)
            authorizationFailure = false
        case "error":
            guard let error = json["error"] as? [String: Any],
                  let code = error["code"] as? Int,
                  let message = error["message"] as? String,
                  let failure = json["authorizationFailure"] as? Bool else { return nil }
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
        self.id = id
        self.name = name
        self.provider = provider
        self.payload = payload
        self.mutation = nil
        self.approvedAccounts = []
        self.approvalCommitted = committed
        self.authorizationFailure = authorizationFailure
    }

}

struct RPCResponseToExtension {
    private let wire: WireProtocol.RPCResponse

    init?(upstream: [String: Any], expectedResponseID: Int) {
        var envelope = [String: Any]()
        envelope["id"] = upstream["id"]
        envelope["jsonrpc"] = upstream["jsonrpc"]
        envelope["result"] = upstream["result"]
        envelope["error"] = upstream["error"]
        guard let wire = WireProtocol.RPCResponse(json: envelope),
              wire.json["id"] as? Int == expectedResponseID else { return nil }
        self.wire = wire
    }

    var json: [String: Any] { wire.json }
}
