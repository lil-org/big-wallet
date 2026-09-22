// ∅ 2026 lil org

import Foundation

enum PopupResponse: Encodable {
    case queue(PopupQueueResponse)
    case command(PopupCommandResponse)
    case queueUnavailable

    private enum CodingKeys: String, CodingKey { case status }

    var approvalState: PopupApprovalState? {
        switch self {
        case .command(let command): return command.approvalState
        case .queue, .queueUnavailable: return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .queue(let queue): try queue.encode(to: encoder)
        case .command(let command): try command.encode(to: encoder)
        case .queueUnavailable:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("unavailable", forKey: .status)
        }
    }

    fileprivate var removingDecorativeImages: Self {
        guard case .command(let command) = self,
              var state = command.approvalState,
              case .review(var review, let actions, let feedback) = state.content else {
            return self
        }
        review.removeDecorativeImages()
        state.content = .review(review, actions: actions, feedback: feedback)
        return .command(command.replacingApprovalState(state))
    }
}

enum PopupCommandResponse: Encodable {
    case ok(PopupApprovalState)
    case ignored(PopupApprovalState?)
    case unavailable

    private enum CodingKeys: String, CodingKey { case status, approval }

    var approvalState: PopupApprovalState? {
        switch self {
        case .ok(let state): return state
        case .ignored(let state): return state
        case .unavailable: return nil
        }
    }

    fileprivate func replacingApprovalState(_ state: PopupApprovalState) -> Self {
        switch self {
        case .ok: return .ok(state)
        case .ignored: return .ignored(state)
        case .unavailable: return .unavailable
        }
    }

    func encode(to encoder: Encoder) throws {
        let status: String
        switch self {
        case .ok: status = "ok"
        case .ignored: status = "ignored"
        case .unavailable: status = "unavailable"
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(approvalState, forKey: .approval)
    }
}

struct PopupQueueResponse: Encodable {
    enum LayoutDirection: String, Encodable { case ltr, rtl }

    let requests: [PopupPendingRequest]
    let completedResponses: [PopupCompletedResponse]
    let strings: [String: String]
    let layoutDirection: LayoutDirection
}

struct PopupPendingRequest: Encodable {
    let id: Int
    let host: String
    let receivedAt: Double
    let sequence: Int
    let requestToken: String
    let enqueueAttempt: String
    let configurationKey: String
    let provider: InpageProvider
    let revisions: ExtensionBridge.ProviderRevisions
}

struct PopupCompletedResponse: Encodable {
    let id: Int
    let host: String
    let configurationKey: String
    let requestToken: String
    let revisions: ExtensionBridge.ProviderRevisions
}

struct PopupApprovalState: Encodable {
    enum Action: String, Encodable {
        case approve, reject, editTransaction, setTransactionSpeed, resolveApprovalAlert
    }

    enum RecoveryAction: String, Encodable { case retry, reject }

    enum Content {
        case review(PopupReview, actions: [Action], feedback: String?)
        case authenticating, working, missing
        case error(message: String, actions: [RecoveryAction])
    }

    let id: Int
    var host: String?
    var content: Content
    var editsError: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, host, state, actions, error, review, editsError
    }

    var canReject: Bool {
        switch content {
        case .review(_, let actions, _): return actions.contains(.reject)
        case .error(_, let actions): return actions.contains(.reject)
        case .authenticating, .working, .missing: return false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let host, !host.isEmpty { try container.encode(host, forKey: .host) }
        try container.encodeIfPresent(editsError, forKey: .editsError)
        switch content {
        case .review(let review, let actions, let feedback):
            try container.encode("review", forKey: .state)
            try container.encode(actions, forKey: .actions)
            try container.encode(review, forKey: .review)
            try container.encodeIfPresent(feedback, forKey: .error)
        case .error(let message, let actions):
            try container.encode("error", forKey: .state)
            try container.encode(actions, forKey: .actions)
            try container.encode(message, forKey: .error)
        case .authenticating:
            try container.encode("authenticating", forKey: .state)
            try container.encode([Action](), forKey: .actions)
        case .working:
            try container.encode("working", forKey: .state)
            try container.encode([Action](), forKey: .actions)
        case .missing:
            try container.encode("missing", forKey: .state)
            try container.encode([Action](), forKey: .actions)
        }
    }
}

struct PopupReview: Encodable {
    enum Content {
        case selectAccount(PopupSelectionReview)
        case switchAccount(PopupSelectionReview)
        case signMessage(PopupMessageReview)
        case sendTransaction(PopupTransactionReview)
        case addChain(PopupChainReview)
    }

    let reviewToken: UUID
    let title: String
    var iconURL: String?
    var content: Content

    private enum CodingKeys: String, CodingKey { case reviewToken, title, iconURL, kind }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reviewToken.uuidString.lowercased(), forKey: .reviewToken)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(iconURL, forKey: .iconURL)
        switch content {
        case .selectAccount(let review):
            try container.encode("selectAccount", forKey: .kind)
            try review.encode(to: encoder)
        case .switchAccount(let review):
            try container.encode("switchAccount", forKey: .kind)
            try review.encode(to: encoder)
        case .signMessage(let review):
            try container.encode("signMessage", forKey: .kind)
            try review.encode(to: encoder)
        case .sendTransaction(let review):
            try container.encode("sendTransaction", forKey: .kind)
            try review.encode(to: encoder)
        case .addChain(let review):
            try container.encode("addChain", forKey: .kind)
            try review.encode(to: encoder)
        }
    }

    mutating func removeDecorativeImages() {
        iconURL = nil
        switch content {
        case .selectAccount(var review):
            review.removeDecorativeImages()
            content = .selectAccount(review)
        case .switchAccount(var review):
            review.removeDecorativeImages()
            content = .switchAccount(review)
        case .signMessage(var review):
            review.account.icon = nil
            content = .signMessage(review)
        case .sendTransaction(var review):
            review.account.icon = nil
            content = .sendTransaction(review)
        case .addChain:
            break
        }
    }
}

struct PopupDisplayAccount: Encodable {
    let name: String
    let croppedAddress: String
    var icon: String?
}

struct PopupSelectableAccount: Encodable {
    var display: PopupDisplayAccount
    let walletId: String
    let address: String
    let coin: InpageProvider
    let derivationPath: String
    let isSelected: Bool

    private enum CodingKeys: String, CodingKey {
        case walletId, address, coin, derivationPath, isSelected
    }

    func encode(to encoder: Encoder) throws {
        try display.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(walletId, forKey: .walletId)
        try container.encode(address, forKey: .address)
        try container.encode(coin, forKey: .coin)
        try container.encode(derivationPath, forKey: .derivationPath)
        try container.encode(isSelected, forKey: .isSelected)
    }
}

struct PopupNetworkOption: Encodable {
    let chainId: String
    let name: String
    let isCustom: Bool
    let isSelected: Bool
}

struct PopupSelectionReview: Encodable {
    var accounts: [PopupSelectableAccount]
    let networks: [PopupNetworkOption]?
    let canSelectNetwork: Bool
    let allowsEmptySelection: Bool
    let emptyMessage: String?
    let primaryTitle: String?

    mutating func removeDecorativeImages() {
        for index in accounts.indices { accounts[index].display.icon = nil }
    }
}

struct PopupClusterOption: Encodable {
    let value: Solana.Cluster
    let label: String
    let isSelected: Bool
}

struct PopupClusterSelection {
    let clusters: [PopupClusterOption]
    let requiresSelection: Bool
}

struct PopupMessageReview: Encodable {
    let meta: String
    var account: PopupDisplayAccount
    let clusterSelection: PopupClusterSelection?

    private enum CodingKeys: String, CodingKey {
        case meta, account, clusters, requiresClusterSelection
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meta, forKey: .meta)
        try container.encode(account, forKey: .account)
        if let clusterSelection {
            try container.encode(clusterSelection.clusters, forKey: .clusters)
            try container.encode(clusterSelection.requiresSelection, forKey: .requiresClusterSelection)
        }
    }
}

struct PopupTransactionReview: Encodable {
    var account: PopupDisplayAccount
    let networkName: String
    let balance: String?
    let valueLine: String?
    let feeLines: [String]
    let dataInterpretation: String?
    let phase: TransactionPreparationState.Phase
    let slider: PopupTransactionSlider
    let editor: PopupTransactionEditor
    let alert: PopupTransactionAlert?
    let editorRequestToken: Int?
}

struct PopupTransactionSlider: Encodable {
    let visible: Bool
    let position: Double
    let maximum: Double
}

struct PopupTransactionEditor: Encodable {
    enum Fee {
        case legacy(gasPriceGwei: String)
        case eip1559(maxPriorityFeePerGasGwei: String, maxFeePerGasGwei: String)
    }

    let nonce: String
    let fee: Fee
    let suggestedFee: Fee?

    private enum CodingKeys: String, CodingKey {
        case nonce, usesEIP1559, gasPriceGwei, maxPriorityFeePerGasGwei, maxFeePerGasGwei
        case suggestedGasPriceGwei, suggestedMaxPriorityFeePerGasGwei, suggestedMaxFeePerGasGwei
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nonce, forKey: .nonce)
        switch fee {
        case .legacy(let gasPrice):
            try container.encode(false, forKey: .usesEIP1559)
            try container.encode(gasPrice, forKey: .gasPriceGwei)
        case .eip1559(let priority, let maximum):
            try container.encode(true, forKey: .usesEIP1559)
            try container.encode(priority, forKey: .maxPriorityFeePerGasGwei)
            try container.encode(maximum, forKey: .maxFeePerGasGwei)
        }
        switch suggestedFee {
        case .legacy(let gasPrice):
            try container.encode(gasPrice, forKey: .suggestedGasPriceGwei)
        case .eip1559(let priority, let maximum):
            try container.encode(priority, forKey: .suggestedMaxPriorityFeePerGasGwei)
            try container.encode(maximum, forKey: .suggestedMaxFeePerGasGwei)
        case nil:
            break
        }
    }
}

struct PopupTransactionAlert: Encodable {
    struct Action: Encodable {
        let title: String
        let action: TransactionApprovalAlertAction
    }

    let title: String
    let message: String
    let actions: [Action]
}

struct PopupChainReview: Encodable {
    let chainName: String
    let rpcURL: String
}

enum PopupResponseEncoder {
    static let maximumResponseBytes = 512 * 1024

    static func encode(_ response: PopupResponse, for request: InternalSafariRequest) throws -> Data {
        let encoder = JSONEncoder()
        func bounded(_ response: PopupResponse) -> Data? {
            guard let data = try? encoder.encode(response),
                  data.count <= maximumResponseBytes else { return nil }
            return data
        }
        if let data = bounded(response) { return data }
        if let data = bounded(response.removingDecorativeImages) { return data }
        guard case .popup(let command) = request.command,
              returnsApprovalState(command) else {
            return try encoder.encode(PopupResponse.queueUnavailable)
        }
        let original = response.approvalState
        guard case .command(let command) = response else {
            return try encoder.encode(PopupResponse.queueUnavailable)
        }
        var fallback = PopupApprovalState(
            id: request.id,
            host: original?.host,
            content: .error(
                message: Strings.somethingWentWrong,
                actions: original?.canReject == true ? [.reject] : [.retry]
            )
        )
        if let data = bounded(.command(command.replacingApprovalState(fallback))) { return data }
        fallback.host = nil
        return try encoder.encode(PopupResponse.command(command.replacingApprovalState(fallback)))
    }

    private static func returnsApprovalState(_ command: InternalSafariRequest.PopupCommand) -> Bool {
        switch command {
        case .getApprovalState, .retryApproval, .applyTransactionEdits,
             .resolveApprovalAlert, .setTransactionSpeed, .approveRequest,
             .rejectRequest:
            return true
        case .getPendingRequests:
            return false
        }
    }
}
