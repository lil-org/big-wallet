// ∅ 2026 lil org

import Foundation

struct InternalSafariRequest: Decodable {

    struct SelectedAccount: Decodable {
        let walletId: String
        let address: String
        let coin: InpageProvider

        init(from decoder: Decoder) throws {
            let container = try ExactKeyedContainer(
                decoder: decoder,
                required: ["walletId", "address", "coin"]
            )
            walletId = try container.decode(String.self, forKey: "walletId")
            address = try container.decode(String.self, forKey: "address")
            coin = try container.decode(InpageProvider.self, forKey: "coin")
        }
    }

    struct ApprovalStatePayload: Decodable {
        enum Mode: String, Decodable {
            case full, poll
        }

        let mode: Mode

        init(from decoder: Decoder) throws {
            let container = try ExactKeyedContainer(
                decoder: decoder,
                required: ["mode"]
            )
            mode = try container.decode(Mode.self, forKey: "mode")
        }
    }

    struct ApprovalPayload: Decodable {
        private struct Revisions: Decodable {
            let value: ExtensionBridge.ProviderRevisions

            init(from decoder: Decoder) throws {
                let container = try ExactKeyedContainer(
                    decoder: decoder,
                    required: ["ethereum", "solana"]
                )
                let ethereum = try container.decode(Int.self, forKey: "ethereum")
                let solana = try container.decode(Int.self, forKey: "solana")
                guard let value = ExtensionBridge.ProviderRevisions(rawValue: [
                    "ethereum": ethereum,
                    "solana": solana,
                ]) else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "invalid provider revisions"
                        )
                    )
                }
                self.value = value
            }
        }

        let password: String?
        let selectedAccounts: [SelectedAccount]?
        let chainId: String?
        let cluster: Solana.Cluster?
        let revisions: ExtensionBridge.ProviderRevisions?

        init(from decoder: Decoder) throws {
            let container = try ExactKeyedContainer(
                decoder: decoder,
                optional: [
                    "password",
                    "selectedAccounts",
                    "chainId",
                    "cluster",
                    "revisions",
                ]
            )
            password = try container.decodeIfPresent(String.self, forKey: "password")
            selectedAccounts = try container.decodeIfPresent(
                [SelectedAccount].self,
                forKey: "selectedAccounts"
            )
            chainId = try container.decodeIfPresent(String.self, forKey: "chainId")
            cluster = try container.decodeIfPresent(Solana.Cluster.self, forKey: "cluster")
            revisions = try container.decodeIfPresent(
                Revisions.self,
                forKey: "revisions"
            )?.value
        }
    }

    struct TransactionSpeedPayload: Decodable {
        enum Interaction: String, Decodable {
            case ended, cancelled
        }

        let interaction: Interaction
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try ExactKeyedContainer(
                decoder: decoder,
                required: ["interaction", "value"]
            )
            interaction = try container.decode(Interaction.self, forKey: "interaction")
            value = try container.decode(Double.self, forKey: "value")
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

        private enum Mode: String, Decodable {
            case suggested, custom
        }

        init(from decoder: Decoder) throws {
            let modeContainer = try decoder.container(keyedBy: InternalCodingKey.self)
            let mode = try modeContainer.decode(Mode.self, forKey: InternalCodingKey("mode"))
            switch mode {
            case .suggested:
                _ = try ExactKeyedContainer(decoder: decoder, required: ["mode"])
                self = .suggested
            case .custom:
                let container = try ExactKeyedContainer(
                    decoder: decoder,
                    required: ["mode", "nonce"],
                    optional: [
                        "gasPriceGwei",
                        "maxPriorityFeePerGasGwei",
                        "maxFeePerGasGwei",
                    ]
                )
                self = .custom(Custom(
                    nonce: try container.decode(String.self, forKey: "nonce"),
                    gasPriceGwei: try container.decodeIfPresent(
                        String.self,
                        forKey: "gasPriceGwei"
                    ),
                    maxPriorityFeePerGasGwei: try container.decodeIfPresent(
                        String.self,
                        forKey: "maxPriorityFeePerGasGwei"
                    ),
                    maxFeePerGasGwei: try container.decodeIfPresent(
                        String.self,
                        forKey: "maxFeePerGasGwei"
                    )
                ))
            }
        }
    }

    struct ApprovalAlertPayload: Decodable {
        let action: TransactionApprovalAlertAction

        init(from decoder: Decoder) throws {
            let container = try ExactKeyedContainer(
                decoder: decoder,
                required: ["action"]
            )
            action = try container.decode(
                TransactionApprovalAlertAction.self,
                forKey: "action"
            )
        }
    }

    struct ResponseIdentity {
        let configurationKey: String
        let token: ExtensionBridge.RequestToken
    }

    struct PopupIdentity {
        let token: ExtensionBridge.RequestToken
        let reviewToken: UUID?
    }

    enum PageCommand {
        case rpc(body: String, chainId: String)
        case getResponse(ResponseIdentity)

        var subject: Subject.Page {
            switch self {
            case .rpc:
                return .rpc
            case .getResponse:
                return .getResponse
            }
        }
    }

    enum PopupCommand {
        case getPendingRequests
        case getApprovalState(PopupIdentity, ApprovalStatePayload)
        case approveRequest(PopupIdentity, ApprovalPayload)
        case rejectRequest(PopupIdentity)
        case setTransactionSpeed(PopupIdentity, TransactionSpeedPayload)
        case applyTransactionEdits(PopupIdentity, TransactionEditsPayload)
        case resolveApprovalAlert(PopupIdentity, ApprovalAlertPayload)

        var subject: Subject.Popup {
            switch self {
            case .getPendingRequests:
                return .getPendingRequests
            case .getApprovalState:
                return .getApprovalState
            case .approveRequest:
                return .approveRequest
            case .rejectRequest:
                return .rejectRequest
            case .setTransactionSpeed:
                return .setTransactionSpeed
            case .applyTransactionEdits:
                return .applyTransactionEdits
            case .resolveApprovalAlert:
                return .resolveApprovalAlert
            }
        }

        var identity: PopupIdentity? {
            switch self {
            case .getPendingRequests:
                return nil
            case .getApprovalState(let identity, _),
                 .approveRequest(let identity, _),
                 .setTransactionSpeed(let identity, _),
                 .applyTransactionEdits(let identity, _),
                 .resolveApprovalAlert(let identity, _):
                return identity
            case .rejectRequest(let identity):
                return identity
            }
        }
    }

    enum Command {
        case page(PageCommand)
        case popup(PopupCommand)
        case openApp
    }

    let id: Int
    let workflowVersion: Int
    let command: Command

    var subject: Subject {
        switch command {
        case .page(let command):
            return .page(command.subject)
        case .popup(let command):
            return .popup(command.subject)
        case .openApp:
            return .openApp
        }
    }

    var requestToken: String? {
        guard case .popup(let command) = command else { return nil }
        return command.identity?.token.rawValue
    }

    enum Subject: Decodable {
        case page(Page)
        case popup(Popup)
        case openApp

        enum Page: String {
            case getResponse, rpc
        }

        enum Popup: String {
            case getPendingRequests, getApprovalState, approveRequest, rejectRequest
            case setTransactionSpeed, applyTransactionEdits, resolveApprovalAlert
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let page = Page(rawValue: rawValue) {
                self = .page(page)
            } else if let popup = Popup(rawValue: rawValue) {
                self = .popup(popup)
            } else if rawValue == "openApp" {
                self = .openApp
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unknown subject"
                )
            }
        }
    }

    init(from decoder: Decoder) throws {
        let subjectContainer = try decoder.container(keyedBy: InternalCodingKey.self)
        id = try subjectContainer.decode(Int.self, forKey: InternalCodingKey("id"))
        workflowVersion = try subjectContainer.decode(
            Int.self,
            forKey: InternalCodingKey("workflowVersion")
        )
        guard workflowVersion == ExtensionBridge.workflowVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: InternalCodingKey("workflowVersion"),
                in: subjectContainer,
                debugDescription: "unsupported workflow"
            )
        }
        let subject = try subjectContainer.decode(
            Subject.self,
            forKey: InternalCodingKey("subject")
        )
        let common = Set(["id", "workflowVersion", "subject"])
        switch subject {
        case .openApp:
            _ = try ExactKeyedContainer(decoder: decoder, required: common)
            command = .openApp
        case .page(.rpc):
            let container = try ExactKeyedContainer(
                decoder: decoder,
                required: common.union(["body", "chainId"])
            )
            command = .page(.rpc(
                body: try container.decode(String.self, forKey: "body"),
                chainId: try container.decode(String.self, forKey: "chainId")
            ))
        case .page(.getResponse):
            command = .page(.getResponse(try Self.decodeResponseIdentity(
                from: decoder,
                common: common
            )))
        case .popup(.getPendingRequests):
            _ = try ExactKeyedContainer(decoder: decoder, required: common)
            command = .popup(.getPendingRequests)
        case .popup(.rejectRequest):
            let container = try ExactKeyedContainer(
                decoder: decoder,
                required: common.union(["requestToken"])
            )
            command = .popup(.rejectRequest(try Self.decodeIdentity(from: container)))
        case .popup(.getApprovalState):
            let container = try Self.popupContainer(
                decoder: decoder,
                common: common,
                requiresReviewToken: false
            )
            command = .popup(.getApprovalState(
                try Self.decodeIdentity(from: container),
                try container.decode(ApprovalStatePayload.self, forKey: "payload")
            ))
        case .popup(.approveRequest):
            let container = try Self.popupContainer(decoder: decoder, common: common)
            command = .popup(.approveRequest(
                try Self.decodeIdentity(from: container, requiresReviewToken: true),
                try container.decode(ApprovalPayload.self, forKey: "payload")
            ))
        case .popup(.setTransactionSpeed):
            let container = try Self.popupContainer(decoder: decoder, common: common)
            command = .popup(.setTransactionSpeed(
                try Self.decodeIdentity(from: container, requiresReviewToken: true),
                try container.decode(TransactionSpeedPayload.self, forKey: "payload")
            ))
        case .popup(.applyTransactionEdits):
            let container = try Self.popupContainer(decoder: decoder, common: common)
            command = .popup(.applyTransactionEdits(
                try Self.decodeIdentity(from: container, requiresReviewToken: true),
                try container.decode(TransactionEditsPayload.self, forKey: "payload")
            ))
        case .popup(.resolveApprovalAlert):
            let container = try Self.popupContainer(decoder: decoder, common: common)
            command = .popup(.resolveApprovalAlert(
                try Self.decodeIdentity(from: container, requiresReviewToken: true),
                try container.decode(ApprovalAlertPayload.self, forKey: "payload")
            ))
        }
    }

    private static func popupContainer(
        decoder: Decoder,
        common: Set<String>,
        requiresReviewToken: Bool = true
    ) throws -> ExactKeyedContainer {
        let required = common.union(
            requiresReviewToken
                ? ["requestToken", "reviewToken", "payload"]
                : ["requestToken", "payload"]
        )
        return try ExactKeyedContainer(
            decoder: decoder,
            required: required
        )
    }

    private static func decodeIdentity(
        from container: ExactKeyedContainer,
        requiresReviewToken: Bool = false
    ) throws -> PopupIdentity {
        let reviewToken: UUID?
        if requiresReviewToken {
            let rawValue = try container.decode(
                String.self,
                forKey: "reviewToken"
            )
            guard let decoded = ExtensionBridge.lowercaseUUID(rawValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: InternalCodingKey("reviewToken"),
                    in: container.container,
                    debugDescription: "invalid review token"
                )
            }
            reviewToken = decoded
        } else {
            reviewToken = nil
        }
        return PopupIdentity(
            token: try decodeToken(from: container),
            reviewToken: reviewToken
        )
    }

    private static func decodeResponseIdentity(
        from decoder: Decoder,
        common: Set<String>
    ) throws -> ResponseIdentity {
        let container = try ExactKeyedContainer(
            decoder: decoder,
            required: common.union(["configurationKey", "requestToken"])
        )
        return try ResponseIdentity(
            configurationKey: container.decode(String.self, forKey: "configurationKey"),
            token: decodeToken(from: container)
        )
    }

    private static func decodeToken(
        from container: ExactKeyedContainer
    ) throws -> ExtensionBridge.RequestToken {
        let rawValue = try container.decode(String.self, forKey: "requestToken")
        guard let token = ExtensionBridge.RequestToken(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: InternalCodingKey("requestToken"),
                in: container.container,
                debugDescription: "invalid request token"
            )
        }
        return token
    }
}

private struct InternalCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct ExactKeyedContainer {
    let container: KeyedDecodingContainer<InternalCodingKey>

    init(
        decoder: Decoder,
        required: Set<String> = [],
        optional: Set<String> = []
    ) throws {
        container = try decoder.container(keyedBy: InternalCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        let allowed = required.union(optional)
        guard actual.isSubset(of: allowed), required.isSubset(of: actual) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unexpected object shape"
                )
            )
        }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        return try container.decode(type, forKey: InternalCodingKey(key))
    }

    func decodeIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: String
    ) throws -> T? {
        return try container.decodeIfPresent(type, forKey: InternalCodingKey(key))
    }
}
