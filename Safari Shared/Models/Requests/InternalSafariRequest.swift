// ∅ 2026 lil org

import Foundation

struct InternalSafariRequest: Decodable {
    struct SelectedAccount: Decodable {
        let walletId: String
        let address: String
        let coin: InpageProvider
        let derivationPath: String

        init(from decoder: Decoder) throws {
            let fields = NativeRequestFields(try WireProtocol.SelectedAccount(from: decoder).json)
            walletId = try fields.value("walletId")
            address = try fields.value("address")
            coin = try fields.decode("coin")
            derivationPath = try fields.value("derivationPath")
        }
    }

    struct ApprovalPayload: Decodable {
        let selectedAccounts: [SelectedAccount]?
        let chainId: String?
        let cluster: Solana.Cluster?

        init(from decoder: Decoder) throws {
            let fields = NativeRequestFields(try WireProtocol.ApprovalPayload(from: decoder).json)
            selectedAccounts = try fields.decodeOptional("selectedAccounts")
            chainId = try fields.optional("chainId")
            cluster = try fields.decodeOptional("cluster")
        }
    }

    struct TransactionSpeedPayload: Decodable {
        enum Interaction: String, Decodable { case ended, cancelled }

        let interaction: Interaction
        let value: Double

        init(from decoder: Decoder) throws {
            let fields = NativeRequestFields(try WireProtocol.TransactionSpeedPayload(from: decoder).json)
            interaction = try fields.decode("interaction")
            value = try fields.value("value")
        }
    }

    enum TransactionEditsPayload: Decodable {
        case suggested
        case custom(Custom)

        struct Custom {
            let nonce: String
            let gasPriceGwei: String?
            let maxPriorityFeePerGasGwei: String?
            let maxFeePerGasGwei: String?
        }

        init(from decoder: Decoder) throws {
            let fields = NativeRequestFields(try WireProtocol.TransactionEditsPayload(from: decoder).json)
            let mode: String = try fields.value("mode")
            if mode == "suggested" {
                self = .suggested
            } else {
                self = .custom(try Custom(
                    nonce: fields.value("nonce"),
                    gasPriceGwei: fields.optional("gasPriceGwei"),
                    maxPriorityFeePerGasGwei: fields.optional("maxPriorityFeePerGasGwei"),
                    maxFeePerGasGwei: fields.optional("maxFeePerGasGwei")
                ))
            }
        }
    }

    struct ApprovalAlertPayload: Decodable {
        let action: TransactionApprovalAlertAction

        init(from decoder: Decoder) throws {
            let fields = NativeRequestFields(try WireProtocol.ApprovalAlertPayload(from: decoder).json)
            action = try fields.decode("action")
        }
    }

    struct ResponseIdentity {
        let configurationKey: String
        let token: ExtensionBridge.RequestToken
    }

    struct DisconnectIdentity {
        let configurationKey: String
        let provider: InpageProvider
        let attempt: String
        let authority: ExtensionBridge.AuthorityVersion
    }

    struct MaintenanceIdentity {
        let response: ResponseIdentity
        let allowDelivery: Bool
    }

    struct ResponseAcknowledgmentIdentity {
        let configurationKey: String
        let token: ExtensionBridge.RequestToken
    }

    struct PopupIdentity {
        let token: ExtensionBridge.RequestToken
        let reviewToken: UUID?
    }

    enum PageCommand {
        case rpc(body: String, chainId: String)
        case getLatestConfiguration(configurationKey: String)
        case disconnect(DisconnectIdentity)
        case getResponse(ResponseIdentity)
        case acknowledgeResponse(ResponseAcknowledgmentIdentity)
        case showApproval(ResponseAcknowledgmentIdentity)
    }

    enum WorkerCommand {
        case getRecoveryRequests
        case maintainRequest(MaintenanceIdentity)
        case prepareResponseDelivery(ResponseIdentity)
    }

    enum PopupCommand {
        case getPendingRequests
        case getApprovalState(PopupIdentity)
        case retryApproval(PopupIdentity)
        case approveRequest(PopupIdentity, ApprovalPayload)
        case rejectRequest(PopupIdentity)
        case setTransactionSpeed(PopupIdentity, TransactionSpeedPayload)
        case applyTransactionEdits(PopupIdentity, TransactionEditsPayload)
        case resolveApprovalAlert(PopupIdentity, ApprovalAlertPayload)

        var identity: PopupIdentity? {
            switch self {
            case .getPendingRequests:
                return nil
            case .getApprovalState(let identity), .retryApproval(let identity),
                 .approveRequest(let identity, _), .rejectRequest(let identity),
                 .setTransactionSpeed(let identity, _), .applyTransactionEdits(let identity, _),
                 .resolveApprovalAlert(let identity, _):
                return identity
            }
        }
    }

    enum Command {
        case page(PageCommand)
        case worker(WorkerCommand)
        case popup(PopupCommand)
        case openApp
    }

    let id: Int
    let workflowVersion: Int
    let command: Command

    var requestToken: String? {
        guard case .popup(let command) = command else { return nil }
        return command.identity?.token.rawValue
    }

    init(from decoder: Decoder) throws {
        let fields = NativeRequestFields(try WireProtocol.NativeCommand(from: decoder).json)
        id = try fields.value("id")
        workflowVersion = try fields.value("workflowVersion")
        let subject: String = try fields.value("subject")
        switch subject {
        case "openApp":
            command = .openApp
        case "rpc":
            command = .page(try .rpc(body: fields.value("body"), chainId: fields.value("chainId")))
        case "getLatestConfiguration":
            command = .page(try .getLatestConfiguration(configurationKey: fields.value("configurationKey")))
        case "disconnect":
            command = .page(.disconnect(try DisconnectIdentity(
                configurationKey: fields.value("configurationKey"),
                provider: fields.decode("provider"),
                attempt: fields.value("attempt"),
                authority: fields.decode("authority")
            )))
        case "getResponse":
            command = .page(.getResponse(try fields.responseIdentity()))
        case "maintainRequest":
            command = .worker(.maintainRequest(try MaintenanceIdentity(
                response: fields.responseIdentity(), allowDelivery: fields.value("allowDelivery")
            )))
        case "prepareResponseDelivery":
            command = .worker(.prepareResponseDelivery(try fields.responseIdentity()))
        case "getRecoveryRequests":
            command = .worker(.getRecoveryRequests)
        case "acknowledgeResponse", "showApproval":
            let identity = try ResponseAcknowledgmentIdentity(
                configurationKey: fields.value("configurationKey"), token: fields.token()
            )
            command = .page(subject == "showApproval" ? .showApproval(identity) : .acknowledgeResponse(identity))
        case "getPendingRequests":
            command = .popup(.getPendingRequests)
        case "rejectRequest":
            command = .popup(.rejectRequest(try fields.popupIdentity()))
        case "getApprovalState":
            command = .popup(.getApprovalState(try fields.popupIdentity()))
        case "retryApproval":
            command = .popup(.retryApproval(try fields.popupIdentity()))
        case "approveRequest":
            command = .popup(try .approveRequest(fields.popupIdentity(), fields.decode("payload")))
        case "setTransactionSpeed":
            command = .popup(try .setTransactionSpeed(fields.popupIdentity(), fields.decode("payload")))
        case "applyTransactionEdits":
            command = .popup(try .applyTransactionEdits(fields.popupIdentity(), fields.decode("payload")))
        case "resolveApprovalAlert":
            command = .popup(try .resolveApprovalAlert(fields.popupIdentity(), fields.decode("payload")))
        default:
            throw fields.invalid("subject")
        }
    }
}

private struct NativeRequestFields {
    private let json: [String: Any]

    init(_ json: [String: Any]) { self.json = json }

    func value<Value>(_ key: String) throws -> Value {
        guard let value = json[key] as? Value else { throw invalid(key) }
        return value
    }

    func optional<Value>(_ key: String) throws -> Value? {
        guard json[key] != nil else { return nil }
        return try value(key)
    }

    func decode<Value: Decodable>(_ key: String) throws -> Value {
        guard let value = json[key] else { throw invalid(key) }
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(
            withJSONObject: value, options: .fragmentsAllowed
        ))
    }

    func decodeOptional<Value: Decodable>(_ key: String) throws -> Value? {
        guard json[key] != nil else { return nil }
        return try decode(key)
    }

    func token() throws -> ExtensionBridge.RequestToken {
        guard let token = ExtensionBridge.RequestToken(rawValue: try value("requestToken")) else {
            throw invalid("requestToken")
        }
        return token
    }

    func responseIdentity() throws -> InternalSafariRequest.ResponseIdentity {
        try .init(configurationKey: value("configurationKey"), token: token())
    }

    func popupIdentity() throws -> InternalSafariRequest.PopupIdentity {
        let rawReviewToken: String? = try optional("reviewToken")
        let reviewToken = rawReviewToken.flatMap(UUID.init(uuidString:))
        guard rawReviewToken == nil || reviewToken != nil else { throw invalid("reviewToken") }
        return try .init(token: token(), reviewToken: reviewToken)
    }

    func invalid(_ key: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "invalid native request field: \(key)"))
    }
}
