// ∅ 2026 lil org

import Foundation

public enum PopupResponse: Encodable, Sendable {
    case queue(PopupQueueResponse)
    case command(PopupCommandResponse)
    case queueUnavailable

    private enum CodingKeys: String, CodingKey, Sendable { case status }

    public var approvalState: PopupApprovalState? {
        switch self {
        case .command(let command): return command.approvalState
        case .queue, .queueUnavailable: return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .queue(let queue): try queue.encode(to: encoder)
        case .command(let command): try command.encode(to: encoder)
        case .queueUnavailable:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("unavailable", forKey: .status)
        }
    }

    package var removingDecorativeImages: Self {
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

public enum PopupCommandStatus: Sendable {
    case ok(editsError: Bool = false)
    case ignored
    case unavailable
}

public struct PopupCommandResponse: Encodable, Sendable {
    public let status: PopupCommandStatus
    public var approvalState: PopupApprovalState?

    private enum CodingKeys: String, CodingKey, Sendable { case status, approval, editsError }

    package func replacingApprovalState(_ state: PopupApprovalState) -> Self {
        var response = self
        response.approvalState = state
        return response
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch status {
        case .ok(let editsError):
            try container.encode("ok", forKey: .status)
            if editsError { try container.encode(true, forKey: .editsError) }
        case .ignored:
            try container.encode("ignored", forKey: .status)
        case .unavailable:
            try container.encode("unavailable", forKey: .status)
        }
        try container.encode(approvalState, forKey: .approval)
    }

    public init(status: PopupCommandStatus, approvalState: PopupApprovalState?) {
        self.status = status
        self.approvalState = approvalState
    }
}

public struct PopupQueueResponse: Encodable, Sendable {
    public enum LayoutDirection: String, Encodable, Sendable { case ltr, rtl }

    public let requests: [PopupPendingRequest]
    public let completedResponses: [PopupCompletedResponse]
    public let strings: [String: String]
    public let layoutDirection: LayoutDirection

    public init(requests: [PopupPendingRequest], completedResponses: [PopupCompletedResponse], strings: [String: String], layoutDirection: LayoutDirection) {
        self.requests = requests
        self.completedResponses = completedResponses
        self.strings = strings
        self.layoutDirection = layoutDirection
    }
}

public struct PopupPendingRequest: Encodable, Sendable {
    public let id: Int
    public let host: String
    public let receivedAt: Double
    public let sequence: Int
    public let requestToken: String
    public let enqueueAttempt: String
    public let configurationKey: String
    public let provider: InpageProvider

    public init(id: Int, host: String, receivedAt: Double, sequence: Int, requestToken: String, enqueueAttempt: String, configurationKey: String, provider: InpageProvider) {
        self.id = id
        self.host = host
        self.receivedAt = receivedAt
        self.sequence = sequence
        self.requestToken = requestToken
        self.enqueueAttempt = enqueueAttempt
        self.configurationKey = configurationKey
        self.provider = provider
    }
}

public struct PopupCompletedResponse: Encodable, Sendable {
    public let id: Int
    public let host: String
    public let configurationKey: String
    public let requestToken: String

    public init(id: Int, host: String, configurationKey: String, requestToken: String) {
        self.id = id
        self.host = host
        self.configurationKey = configurationKey
        self.requestToken = requestToken
    }
}

public struct PopupApprovalState: Encodable, Sendable {
    public enum Action: String, Encodable, Sendable {
        case approve, reject, editTransaction, setTransactionSpeed, retryTransaction
    }

    public enum RecoveryAction: String, Encodable, Sendable { case retry, reject }

    public enum Content: Sendable {
        case review(PopupReview, actions: [Action], feedback: String?)
        case authenticating, working, missing
        case error(message: String, actions: [RecoveryAction])
    }

    public let id: Int
    public var host: String?
    public var content: Content

    private enum CodingKeys: String, CodingKey, Sendable {
        case id, host, state, actions, error, review
    }

    public var canReject: Bool {
        switch content {
        case .review(_, let actions, _): return actions.contains(.reject)
        case .error(_, let actions): return actions.contains(.reject)
        case .authenticating, .working, .missing: return false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let host, !host.isEmpty { try container.encode(host, forKey: .host) }
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

    public init(id: Int, host: String? = nil, content: Content) {
        self.id = id
        self.host = host
        self.content = content
    }
}

public struct PopupReview: Encodable, Sendable {
    public enum Content: Sendable {
        case accountSelection(PopupSelectionReview)
        case signMessage(PopupMessageReview)
        case sendTransaction(PopupTransactionReview)
        case addChain(PopupChainReview)
    }

    public let reviewToken: UUID
    public let title: String
    public var content: Content

    private enum CodingKeys: String, CodingKey, Sendable { case reviewToken, title, kind }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reviewToken.uuidString.lowercased(), forKey: .reviewToken)
        try container.encode(title, forKey: .title)
        switch content {
        case .accountSelection(let review):
            try container.encode("accountSelection", forKey: .kind)
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

    public mutating func removeDecorativeImages() {
        switch content {
        case .accountSelection(var review):
            review.removeDecorativeImages()
            content = .accountSelection(review)
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

    public init(reviewToken: UUID, title: String, content: Content) {
        self.reviewToken = reviewToken
        self.title = title
        self.content = content
    }
}

public struct PopupDisplayAccount: Encodable, Sendable {
    public let name: String
    public let croppedAddress: String
    public var icon: String?

    public init(name: String, croppedAddress: String, icon: String?) {
        self.name = name
        self.croppedAddress = croppedAddress
        self.icon = icon
    }
}

public struct PopupSelectableAccount: Encodable, Sendable {
    public var display: PopupDisplayAccount
    public let walletId: String
    public let address: String
    public let coin: InpageProvider
    public let derivationPath: String
    public let isSelected: Bool

    private enum CodingKeys: String, CodingKey, Sendable {
        case walletId, address, coin, derivationPath, isSelected
    }

    public func encode(to encoder: Encoder) throws {
        try display.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(walletId, forKey: .walletId)
        try container.encode(address, forKey: .address)
        try container.encode(coin, forKey: .coin)
        try container.encode(derivationPath, forKey: .derivationPath)
        try container.encode(isSelected, forKey: .isSelected)
    }

    public init(display: PopupDisplayAccount, walletId: String, address: String, coin: InpageProvider, derivationPath: String, isSelected: Bool) {
        self.display = display
        self.walletId = walletId
        self.address = address
        self.coin = coin
        self.derivationPath = derivationPath
        self.isSelected = isSelected
    }
}

public struct PopupNetworkOption: Encodable, Sendable {
    public let chainId: String
    public let name: String
    public let isCustom: Bool
    public let isSelected: Bool

    public init(chainId: String, name: String, isCustom: Bool, isSelected: Bool) {
        self.chainId = chainId
        self.name = name
        self.isCustom = isCustom
        self.isSelected = isSelected
    }
}

public struct PopupSelectionReview: Encodable, Sendable {
    public var accounts: [PopupSelectableAccount]
    public let networks: [PopupNetworkOption]?
    public let canSelectNetwork: Bool
    public let allowsEmptySelection: Bool
    public let emptyMessage: String?
    public let primaryTitle: String?

    public mutating func removeDecorativeImages() {
        for index in accounts.indices { accounts[index].display.icon = nil }
    }

    public init(accounts: [PopupSelectableAccount], networks: [PopupNetworkOption]?, canSelectNetwork: Bool, allowsEmptySelection: Bool, emptyMessage: String?, primaryTitle: String?) {
        self.accounts = accounts
        self.networks = networks
        self.canSelectNetwork = canSelectNetwork
        self.allowsEmptySelection = allowsEmptySelection
        self.emptyMessage = emptyMessage
        self.primaryTitle = primaryTitle
    }
}

public struct PopupClusterOption: Encodable, Sendable {
    public let value: Solana.Cluster
    public let label: String
    public let isSelected: Bool

    public init(value: Solana.Cluster, label: String, isSelected: Bool) {
        self.value = value
        self.label = label
        self.isSelected = isSelected
    }
}

public struct PopupClusterSelection: Sendable {
    public let clusters: [PopupClusterOption]
    public let requiresSelection: Bool

    public init(clusters: [PopupClusterOption], requiresSelection: Bool) {
        self.clusters = clusters
        self.requiresSelection = requiresSelection
    }
}

public struct PopupMessageReview: Encodable, Sendable {
    public let meta: String
    public var account: PopupDisplayAccount
    public let clusterSelection: PopupClusterSelection?

    private enum CodingKeys: String, CodingKey, Sendable {
        case meta, account, clusters, requiresClusterSelection
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meta, forKey: .meta)
        try container.encode(account, forKey: .account)
        if let clusterSelection {
            try container.encode(clusterSelection.clusters, forKey: .clusters)
            try container.encode(clusterSelection.requiresSelection, forKey: .requiresClusterSelection)
        }
    }

    public init(meta: String, account: PopupDisplayAccount, clusterSelection: PopupClusterSelection?) {
        self.meta = meta
        self.account = account
        self.clusterSelection = clusterSelection
    }
}

public struct PopupTransactionReview: Encodable, Sendable {
    public var account: PopupDisplayAccount
    public let networkName: String
    public let balance: String?
    public let valueLine: String?
    public let feeLines: [String]
    public let dataInterpretation: String?
    public let canBackOffRefresh: Bool
    public let slider: PopupTransactionSlider
    public let editor: PopupTransactionEditor
    public let notice: PopupTransactionNotice?

    public init(account: PopupDisplayAccount, networkName: String, balance: String?, valueLine: String?, feeLines: [String], dataInterpretation: String?, canBackOffRefresh: Bool, slider: PopupTransactionSlider, editor: PopupTransactionEditor, notice: PopupTransactionNotice?) {
        self.account = account
        self.networkName = networkName
        self.balance = balance
        self.valueLine = valueLine
        self.feeLines = feeLines
        self.dataInterpretation = dataInterpretation
        self.canBackOffRefresh = canBackOffRefresh
        self.slider = slider
        self.editor = editor
        self.notice = notice
    }
}

public struct PopupTransactionSlider: Encodable, Sendable {
    public let visible: Bool
    public let position: Double
    public let maximum: Double

    public init(visible: Bool, position: Double, maximum: Double) {
        self.visible = visible
        self.position = position
        self.maximum = maximum
    }
}

public struct PopupTransactionEditor: Encodable, Sendable {
    public enum Fee: Sendable {
        case legacy(gasPriceGwei: String)
        case eip1559(maxPriorityFeePerGasGwei: String, maxFeePerGasGwei: String)
    }

    public let nonce: String
    public let fee: Fee
    public let suggestedFee: Fee?

    private enum CodingKeys: String, CodingKey, Sendable {
        case nonce, usesEIP1559, gasPriceGwei, maxPriorityFeePerGasGwei, maxFeePerGasGwei
        case suggestedGasPriceGwei, suggestedMaxPriorityFeePerGasGwei, suggestedMaxFeePerGasGwei
    }

    public func encode(to encoder: Encoder) throws {
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

    public init(nonce: String, fee: Fee, suggestedFee: Fee?) {
        self.nonce = nonce
        self.fee = fee
        self.suggestedFee = suggestedFee
    }
}

public struct PopupTransactionNotice: Encodable, Sendable {
    public let title: String
    public let message: String?

    public init(title: String, message: String?) {
        self.title = title
        self.message = message
    }
}

public struct PopupChainReview: Encodable, Sendable {
    public let chainName: String
    public let rpcURL: String

    public init(chainName: String, rpcURL: String) {
        self.chainName = chainName
        self.rpcURL = rpcURL
    }
}

