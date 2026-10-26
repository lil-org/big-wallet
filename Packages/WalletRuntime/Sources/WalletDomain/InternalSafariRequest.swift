// ∅ 2026 lil org

import Foundation

public struct InternalSafariRequest: Decodable, Sendable {
    public struct SelectedAccount: Decodable, Sendable {
        public let walletId: String
        public let address: String
        public let coin: InpageProvider
        public let derivationPath: String

        public init(from decoder: Decoder) throws {
            try self.init(validatedJSON: WireProtocol.object(.selectedAccount, from: decoder).json)
        }

        fileprivate init(validatedJSON: [String: Any]) throws {
            let fields = NativeRequestFields(validatedJSON)
            walletId = try fields.value("walletId")
            address = try fields.value("address")
            coin = try fields.enumValue("coin")
            derivationPath = try fields.value("derivationPath")
        }
    }

    public struct ApprovalPayload: Decodable, Sendable {
        public let selectedAccounts: [SelectedAccount]?
        public let chainId: String?
        public let cluster: Solana.Cluster?

        public init(from decoder: Decoder) throws {
            try self.init(validatedJSON: WireProtocol.object(.approvalPayload, from: decoder).json)
        }

        fileprivate init(validatedJSON: [String: Any]) throws {
            let fields = NativeRequestFields(validatedJSON)
            let accounts: [[String: Any]]? = try fields.optional("selectedAccounts")
            selectedAccounts = try accounts?.map(SelectedAccount.init(validatedJSON:))
            chainId = try fields.optional("chainId")
            cluster = try fields.optionalEnumValue("cluster")
        }
    }

    public struct TransactionSpeedPayload: Decodable, Sendable {
        public enum Interaction: String, Decodable, Sendable { case ended, cancelled }

        public let interaction: Interaction
        public let value: Double

        public init(from decoder: Decoder) throws {
            try self.init(validatedJSON: WireProtocol.object(.transactionSpeedPayload, from: decoder).json)
        }

        fileprivate init(validatedJSON: [String: Any]) throws {
            let fields = NativeRequestFields(validatedJSON)
            interaction = try fields.enumValue("interaction")
            value = try fields.value("value")
        }
    }

    public enum TransactionEditsPayload: Decodable, Sendable {
        case suggested
        case custom(Custom)

        public struct Custom: Sendable {
            public let nonce: String
            public let gasPriceGwei: String?
            public let maxPriorityFeePerGasGwei: String?
            public let maxFeePerGasGwei: String?

            public init(nonce: String, gasPriceGwei: String?, maxPriorityFeePerGasGwei: String?, maxFeePerGasGwei: String?) {
                self.nonce = nonce
                self.gasPriceGwei = gasPriceGwei
                self.maxPriorityFeePerGasGwei = maxPriorityFeePerGasGwei
                self.maxFeePerGasGwei = maxFeePerGasGwei
            }
        }

        public init(from decoder: Decoder) throws {
            try self.init(validatedJSON: WireProtocol.object(.transactionEditsPayload, from: decoder).json)
        }

        fileprivate init(validatedJSON: [String: Any]) throws {
            let fields = NativeRequestFields(validatedJSON)
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

    public struct ResponseIdentity: Sendable {
        public let configurationKey: String
        public let token: RequestToken

        public init(configurationKey: String, token: RequestToken) {
            self.configurationKey = configurationKey
            self.token = token
        }
    }

    public struct DisconnectIdentity: Sendable {
        public let configurationKey: String
        public let provider: InpageProvider
        public let attempt: String
        public let authority: RequestAuthorityVersion

        public init(configurationKey: String, provider: InpageProvider, attempt: String, authority: RequestAuthorityVersion) {
            self.configurationKey = configurationKey
            self.provider = provider
            self.attempt = attempt
            self.authority = authority
        }
    }

    public struct ResponsePollIdentity: Sendable {
        public let response: ResponseIdentity
        public let maintenance: ResponseMaintenance

        public init(response: ResponseIdentity, maintenance: ResponseMaintenance) {
            self.response = response
            self.maintenance = maintenance
        }
    }

    public struct ResponseAcknowledgmentIdentity: Sendable {
        public let configurationKey: String
        public let token: RequestToken

        public init(configurationKey: String, token: RequestToken) {
            self.configurationKey = configurationKey
            self.token = token
        }
    }

    public struct PopupIdentity: Sendable {
        public let token: RequestToken
        public let reviewToken: UUID?

        public init(token: RequestToken, reviewToken: UUID?) {
            self.token = token
            self.reviewToken = reviewToken
        }
    }

    public enum PageCommand: Sendable {
        case rpc(body: String, chainId: String)
        case getLatestConfiguration(configurationKey: String)
        case disconnect(DisconnectIdentity)
        case acknowledgeResponse(ResponseAcknowledgmentIdentity)
        case showApproval(ResponseAcknowledgmentIdentity)
    }

    public enum WorkerCommand: Sendable {
        case getRecoveryRequests
        case pollResponse(ResponsePollIdentity)
    }

    public enum PopupCommand: Sendable {
        case getPendingRequests
        case getApprovalState(PopupIdentity)
        case retryApproval(PopupIdentity)
        case approveRequest(PopupIdentity, ApprovalPayload)
        case rejectRequest(PopupIdentity)
        case setTransactionSpeed(PopupIdentity, TransactionSpeedPayload)
        case applyTransactionEdits(PopupIdentity, TransactionEditsPayload)
        case retryTransaction(PopupIdentity)

        public var identity: PopupIdentity? {
            switch self {
            case .getPendingRequests:
                return nil
            case .getApprovalState(let identity), .retryApproval(let identity),
                 .approveRequest(let identity, _), .rejectRequest(let identity),
                 .setTransactionSpeed(let identity, _), .applyTransactionEdits(let identity, _),
                 .retryTransaction(let identity):
                return identity
            }
        }
    }

    public enum Command: Sendable {
        case page(PageCommand)
        case worker(WorkerCommand)
        case popup(PopupCommand)
        case openApp
    }

    public let id: Int
    public let workflowVersion: Int
    public let command: Command

    public var requestToken: String? {
        guard case .popup(let command) = command else { return nil }
        return command.identity?.token.rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(wire: WireProtocol.object(.nativeCommand, from: decoder))
    }

    public init(wire: WireProtocol.ValidatedObject) throws {
        let fields = NativeRequestFields(wire.json)
        guard wire.contract == .nativeCommand else { throw fields.invalid("contract") }
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
            guard let authority = RequestAuthorityVersion(validatedJSON: try fields.value("authority")) else {
                throw fields.invalid("authority")
            }
            command = .page(.disconnect(try DisconnectIdentity(
                configurationKey: fields.value("configurationKey"),
                provider: fields.enumValue("provider"),
                attempt: fields.value("attempt"),
                authority: authority
            )))
        case "pollResponse":
            command = .worker(.pollResponse(try ResponsePollIdentity(
                response: fields.responseIdentity(), maintenance: fields.enumValue("maintenance")
            )))
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
            command = .popup(try .approveRequest(
                fields.popupIdentity(), ApprovalPayload(validatedJSON: fields.value("payload"))
            ))
        case "setTransactionSpeed":
            command = .popup(try .setTransactionSpeed(
                fields.popupIdentity(), TransactionSpeedPayload(validatedJSON: fields.value("payload"))
            ))
        case "applyTransactionEdits":
            command = .popup(try .applyTransactionEdits(
                fields.popupIdentity(), TransactionEditsPayload(validatedJSON: fields.value("payload"))
            ))
        case "retryTransaction":
            command = .popup(.retryTransaction(try fields.popupIdentity()))
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

    func enumValue<Value: RawRepresentable>(_ key: String) throws -> Value where Value.RawValue == String {
        guard let result = Value(rawValue: try value(key)) else { throw invalid(key) }
        return result
    }

    func optionalEnumValue<Value: RawRepresentable>(_ key: String) throws -> Value? where Value.RawValue == String {
        guard json[key] != nil else { return nil }
        return try enumValue(key)
    }

    func token() throws -> RequestToken {
        guard let token = RequestToken(rawValue: try value("requestToken")) else {
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
