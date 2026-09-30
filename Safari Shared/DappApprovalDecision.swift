// ∅ 2026 lil org

import Foundation

enum DappApprovalDecision: Equatable, Sendable {

    struct AccountSelection: Equatable, Sendable {
        let accounts: [WalletAccountDescriptor]
        let ethereumChainID: String?

        init(accounts: [WalletAccountDescriptor], ethereumChainID: String?) {
            self.accounts = accounts
            self.ethereumChainID = ethereumChainID
        }
    }

    struct MessageApproval: Equatable, Sendable {
        let approvedAccount: WalletAccountDescriptor
        let solanaCluster: Solana.Cluster?

        init(approvedAccount: WalletAccountDescriptor, solanaCluster: Solana.Cluster?) {
            self.approvedAccount = approvedAccount
            self.solanaCluster = solanaCluster
        }
    }

    struct NetworkIdentity: Equatable, Sendable {

        enum Source: String, Equatable, Sendable {
            case alchemy, fallback, custom

            init(_ source: RPCSource) {
                switch source {
                case .alchemy:
                    self = .alchemy
                case .fallback:
                    self = .fallback
                case .custom:
                    self = .custom
                }
            }
        }

        let chainID: Int
        let source: Source
        let canonicalRPCURL: String
        let allowsAlchemyAuthorization: Bool

        init?(_ network: ResolvedEthereumNetwork) {
            guard network.network.chainId > 0,
                  let canonicalRPCURL = Self.canonicalRPCURL(
                    network.rpcURL
                  ) else { return nil }
            chainID = network.network.chainId
            source = .init(network.source)
            self.canonicalRPCURL = canonicalRPCURL
            allowsAlchemyAuthorization = network.allowsAlchemyAuthorization
        }

        private static func canonicalRPCURL(_ url: URL) -> String? {
            guard var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ), let scheme = components.scheme?.lowercased(),
               let host = components.host?.lowercased(),
               !scheme.isEmpty,
               !host.isEmpty else { return nil }
            components.scheme = scheme
            components.host = host
            if (scheme == "http" && components.port == 80)
                || (scheme == "https" && components.port == 443) {
                components.port = nil
            }
            components.fragment = nil
            if components.percentEncodedPath.isEmpty {
                components.percentEncodedPath = "/"
            }
            return components.string
        }
    }

    struct TransactionExecution: Equatable, Sendable {
        let approvedAccount: WalletAccountDescriptor
        let nonce: BigUInt
        let gasLimit: BigUInt
        let fee: PreparedTransactionFee
        let feeProvenance: TransactionFeeProvenance
        let feeBasisBaseFeePerGas: BigUInt?
        let reviewedNetwork: NetworkIdentity

        init?(
            _ transaction: Transaction,
            reviewedNetwork: ResolvedEthereumNetwork,
            approvedAccount: WalletAccountDescriptor
        ) {
            guard let nonce = transaction.nonce.flatMap({
                      EthereumQuantity.parseUInt256($0, allowPrefixless: true)
                  }),
                  let gasLimit = transaction.gas.flatMap({
                      EthereumQuantity.parseUInt256($0, allowPrefixless: true)
                  }),
                  let preparedFee = transaction.preparedFee,
                  let networkIdentity = NetworkIdentity(reviewedNetwork) else {
                return nil
            }
            self.nonce = nonce
            self.approvedAccount = approvedAccount
            self.gasLimit = gasLimit
            fee = preparedFee
            feeProvenance = transaction.feeProvenance
            feeBasisBaseFeePerGas = transaction.feeBasisBaseFeePerGas
            self.reviewedNetwork = networkIdentity
        }

        func applying(to action: SendTransactionAction) -> Transaction? {
            guard isApplicable(to: action) else { return nil }
            return applyingValidatedFields(to: action.transaction)
        }

        fileprivate func isApplicable(to action: SendTransactionAction) -> Bool {
            guard let currentNetwork = NetworkIdentity(action.resolvedNetwork),
                  reviewedNetwork == currentNetwork,
                  !gasLimit.isZero,
                  fee.isStructurallyValid,
                  feeBasisBaseFeePerGas.map(Transaction.isValidUInt256) != false else { return false }
            switch fee {
            case .legacy:
                guard feeProvenance.maxPriorityFeePerGas == nil,
                      feeProvenance.maxFeePerGas == nil else { return false }
            case .eip1559:
                guard feeProvenance.gasPrice == nil else { return false }
            }
            return true
        }

        fileprivate func applyingValidatedFields(to transaction: Transaction) -> Transaction {
            var result = transaction
            result.nonce = nonce.toHexString(withPrefix: true)
            result.gas = gasLimit.toHexString(withPrefix: true)
            result.replacePreparedFee(
                fee,
                provenance: feeProvenance
            )
            result.currentBaseFeePerGas = feeBasisBaseFeePerGas
            result.nextBaseFeePerGas = nil
            return result
        }
    }

    case accountSelection(AccountSelection)
    case message(MessageApproval)
    case transaction(TransactionExecution)
    case addEthereumChain
}

@MainActor
final class ApprovalReview {
    private enum State { case open, accepted, invalidated }

    private struct Content {
        let binding: ExtensionBridge.RequestBinding
        let action: DappRequestAction
    }

    private let content: Content
    private var state = State.open

    var binding: ExtensionBridge.RequestBinding { content.binding }
    var request: SafariRequest { content.binding.request }
    var action: DappRequestAction { content.action }

    init?(binding: ExtensionBridge.RequestBinding, action: DappRequestAction) {
        guard let action = Self.boundAction(action, request: binding.request) else { return nil }
        content = Content(binding: binding, action: action)
    }

    private init(content: Content) {
        self.content = content
    }

    func renewed() -> ApprovalReview {
        ApprovalReview(content: content)
    }

    func invalidate() {
        if case .open = state { state = .invalidated }
    }

    func acceptAccounts(
        selection: DappApprovalDecision.AccountSelection,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        switch action {
        case .selectAccount, .switchAccount:
            return accept(.accountSelection(selection), approvedAt: approvedAt, nativeReceipt: nativeReceipt)
        default:
            return nil
        }
    }

    func acceptMessage(
        cluster: Solana.Cluster?,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        guard case .approveMessage(let action) = action else { return nil }
        return accept(.message(.init(
            approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account),
            solanaCluster: cluster
        )), approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    func acceptTransaction(
        execution: DappApprovalDecision.TransactionExecution,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        guard case .approveTransaction = action else { return nil }
        return accept(.transaction(execution), approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    func acceptAddEthereumChain(
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
    ) -> ReviewConsent? {
        guard case .addEthereumChain = action else { return nil }
        return accept(.addEthereumChain, approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    private func accept(
        _ decision: DappApprovalDecision,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    ) -> ReviewConsent? {
        guard case .open = state,
              approvedAt.timeIntervalSince1970.isFinite else { return nil }
        state = .accepted
        return ReviewConsent(review: self, decision: decision, approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

    private static func boundAction(
        _ action: DappRequestAction,
        request: SafariRequest
    ) -> DappRequestAction? {
        switch (action, request.body) {
        case (.selectAccount(let selection), .ethereum(let body)):
            guard body.method == .requestAccounts, selection.coinType == .ethereum,
                  selection.initiallyConnectedProviders.isEmpty else { return nil }
            return action
        case (.selectAccount(let selection), .solana(let body)):
            guard body.method == .connect, selection.coinType == .solana,
                  !body.onlyIfTrusted, selection.initiallyConnectedProviders.isEmpty else { return nil }
            return action
        case (.switchAccount(let selection), .unknown(let body)):
            let providers = Set(body.providerConfigurations.compactMap { configuration -> InpageProvider? in
                guard configuration.provider == .ethereum || configuration.provider == .solana,
                      configuration.provider != .ethereum || configuration.address?.isEmpty == false else { return nil }
                return configuration.provider
            })
            guard selection.coinType == nil, selection.initiallyConnectedProviders == providers else { return nil }
            return action
        case (.approveMessage(let message), _):
            let descriptor = WalletAccountDescriptor(walletID: message.walletId, account: message.account)
            guard descriptor.isValid, request.authorizedAccount == descriptor else { return nil }
            switch request.body {
            case .ethereum(let body):
                guard descriptor.coin == .ethereum,
                      descriptor.normalizedAddress == WalletCoin.ethereum.normalizedAddress(body.address) else { return nil }
            case .solana(let body):
                guard descriptor.coin == .solana,
                      descriptor.normalizedAddress == body.publicKey else { return nil }
            case .unknown:
                return nil
            }
            guard let canonical = DappRequestProcessor.signingReviewContent(for: request),
                  canonical.subject == message.subject,
                  canonical.meta == message.meta,
                  DappApprovalValidator.messagePayloadMatches(message.payload, canonical.payload) else { return nil }
            return .approveMessage(SignMessageAction(
                subject: canonical.subject, walletId: message.walletId,
                account: message.account, meta: canonical.meta, payload: canonical.payload
            ))
        case (.approveTransaction(let transaction), .ethereum(let body)):
            guard body.method == .signTransaction,
                  body.currentChainId == transaction.chain.chainId,
                  request.authorizedAccount == WalletAccountDescriptor(
                    walletID: transaction.walletId, account: transaction.account
                  ),
                  case .success(let canonical) = body.transactionParsingResult,
                  DappApprovalValidator.transactionIntentMatches(canonical, transaction.transaction) else { return nil }
            return .approveTransaction(SendTransactionAction(
                transaction: canonical, resolvedNetwork: transaction.resolvedNetwork,
                walletId: transaction.walletId, account: transaction.account
            ))
        case (.addEthereumChain(let addition), .ethereum(let body)):
            guard body.method == .addEthereumChain,
                  let requested = EthereumNetworkFromDapp.from(body.parameters) else { return nil }
            guard DappApprovalValidator.networkDefinitionMatches(requested, addition.chainToAdd) else { return nil }
            return .addEthereumChain(AddEthereumChainAction(chainToAdd: requested))
        default:
            return nil
        }
    }

}

fileprivate final class ConsentAuthorizationUse: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

struct ReviewConsent: Sendable {
    let review: ApprovalReview
    private let authorizationUse: ConsentAuthorizationUse
    let decision: DappApprovalDecision
    let approvedAt: Date
    let nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?

    fileprivate init(
        review: ApprovalReview,
        decision: DappApprovalDecision,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    ) {
        self.review = review
        authorizationUse = ConsentAuthorizationUse()
        self.decision = decision
        self.approvedAt = approvedAt
        self.nativeReceipt = nativeReceipt
    }

    @MainActor
    func resolve(
        currentAction: DappRequestAction? = nil,
        accounts: [SpecificWalletAccount]?,
        networkResolver: (String) -> EthereumNetwork?
    ) -> Result<ResolvedDappApproval, DappApprovalValidator.Failure> {
        return DappApprovalValidator.resolve(
            reviewedAction: review.action, currentAction: currentAction,
            decision: decision, accounts: accounts, networkResolver: networkResolver
        ).map { approval in
            ResolvedDappApproval(
                binding: review.binding, request: review.request, approval: approval,
                nativeReceipt: nativeReceipt, approvedAt: approvedAt,
                authorizationUse: authorizationUse
            )
        }
    }
}

struct ResolvedDappApproval: @unchecked Sendable {
    let binding: ExtensionBridge.RequestBinding
    let request: SafariRequest
    let approval: DappApprovalValidator.Approval
    private let authorizationUse: ConsentAuthorizationUse
    let nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    let approvedAt: Date

    fileprivate init(
        binding: ExtensionBridge.RequestBinding,
        request: SafariRequest,
        approval: DappApprovalValidator.Approval,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?,
        approvedAt: Date,
        authorizationUse: ConsentAuthorizationUse
    ) {
        self.binding = binding
        self.request = request
        self.approval = approval
        self.authorizationUse = authorizationUse
        self.nativeReceipt = nativeReceipt
        self.approvedAt = approvedAt
    }

    func consumeAuthorization() -> Bool {
        authorizationUse.consume()
    }
}

enum DappApprovalValidator {

    struct Selection {
        let accounts: [SpecificWalletAccount]
        let network: EthereumNetwork?
    }

    struct Approval {
        enum Kind {
            case accountSelection(SelectAccountAction, Selection)
            case signing(
                approvedAccount: WalletAccountDescriptor,
                payload: ApprovedWalletSigningOperation.Payload
            )
            case addEthereumChain(AddEthereumChainAction)
        }

        let kind: Kind

        fileprivate init(_ kind: Kind) {
            self.kind = kind
        }

        var signingAccount: WalletAccountDescriptor? {
            switch kind {
            case .signing(let approvedAccount, _):
                return approvedAccount
            case .accountSelection, .addEthereumChain:
                return nil
            }
        }
    }

    enum Failure: Error {
        case invalidDecision
        case staleTransaction
        case staleAccount
    }

    static func resolve(
        action: DappRequestAction,
        decision: DappApprovalDecision,
        accounts: [SpecificWalletAccount]?,
        networkResolver: (String) -> EthereumNetwork?
    ) -> Result<Approval, Failure> {
        resolve(
            action: action, reviewedAction: nil, decision: decision,
            accounts: accounts, networkResolver: networkResolver
        )
    }

    fileprivate static func resolve(
        reviewedAction: DappRequestAction,
        currentAction: DappRequestAction?,
        decision: DappApprovalDecision,
        accounts: [SpecificWalletAccount]?,
        networkResolver: (String) -> EthereumNetwork?
    ) -> Result<Approval, Failure> {
        resolve(
            action: currentAction ?? reviewedAction,
            reviewedAction: currentAction.map { _ in reviewedAction },
            decision: decision, accounts: accounts, networkResolver: networkResolver
        )
    }

    private static func resolve(
        action: DappRequestAction,
        reviewedAction: DappRequestAction?,
        decision: DappApprovalDecision,
        accounts: [SpecificWalletAccount]?,
        networkResolver: (String) -> EthereumNetwork?
    ) -> Result<Approval, Failure> {
        func canonicalAction() -> DappRequestAction? {
            guard let reviewedAction else { return action }
            return matchingAction(action, reviewedAction: reviewedAction)
        }

        switch (action, decision) {
        case (.selectAccount, .accountSelection(let selection)),
             (.switchAccount, .accountSelection(let selection)):
            let action: SelectAccountAction
            switch canonicalAction() {
            case .selectAccount(let selection)?, .switchAccount(let selection)?:
                action = selection
            default:
                return .failure(.invalidDecision)
            }
            guard let accounts,
                  let resolved = resolveSelection(
                    action: action,
                    selection: selection,
                    accounts: accounts,
                    networkResolver: networkResolver
                  ) else { return .failure(.invalidDecision) }
            return .success(Approval(.accountSelection(action, resolved)))
        case (.approveMessage(let action), .message(let approval)):
            guard approval.approvedAccount.matches(walletID: action.walletId, account: action.account) else {
                return .failure(.staleAccount)
            }
            guard case .approveMessage(let canonical)? = canonicalAction() else {
                return .failure(.invalidDecision)
            }
            guard let payload = resolveMessagePayload(
                canonical.payload,
                cluster: approval.solanaCluster
            ) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(
                approvedAccount: approval.approvedAccount,
                payload: payload
            )))
        case (.approveTransaction(let action), .transaction(let execution)):
            guard execution.approvedAccount.matches(walletID: action.walletId, account: action.account) else {
                return .failure(.staleAccount)
            }
            guard execution.isApplicable(to: action) else {
                return .failure(.staleTransaction)
            }
            guard case .approveTransaction(let canonical)? = canonicalAction() else {
                return .failure(.invalidDecision)
            }
            let transaction = execution.applyingValidatedFields(to: canonical.transaction)
            guard transaction.isReadyForApproval(on: canonical.chain) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(
                approvedAccount: execution.approvedAccount,
                payload: .ethereumTransaction(transaction, canonical.resolvedNetwork)
            )))
        case (.addEthereumChain, .addEthereumChain):
            guard case .addEthereumChain(let canonical)? = canonicalAction() else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.addEthereumChain(canonical)))
        default:
            return .failure(.invalidDecision)
        }
    }

    private static func matchingAction(
        _ action: DappRequestAction,
        reviewedAction: DappRequestAction
    ) -> DappRequestAction? {
        switch (action, reviewedAction) {
        case (.selectAccount(let current), .selectAccount(let reviewed)),
             (.switchAccount(let current), .switchAccount(let reviewed)):
            guard current.coinType == reviewed.coinType,
                  current.initiallyConnectedProviders == reviewed.initiallyConnectedProviders else { return nil }
            return action
        case (.approveMessage(let current), .approveMessage(let reviewed)):
            guard WalletAccountDescriptor(walletID: current.walletId, account: current.account) ==
                    WalletAccountDescriptor(walletID: reviewed.walletId, account: reviewed.account),
                  current.subject == reviewed.subject,
                  current.meta == reviewed.meta,
                  messagePayloadMatches(current.payload, reviewed.payload) else { return nil }
            return reviewedAction
        case (.approveTransaction(let current), .approveTransaction(let reviewed)):
            guard current.chain.chainId == reviewed.chain.chainId,
                  WalletAccountDescriptor(walletID: current.walletId, account: current.account) ==
                    WalletAccountDescriptor(walletID: reviewed.walletId, account: reviewed.account),
                  transactionIntentMatches(current.transaction, reviewed.transaction) else { return nil }
            return .approveTransaction(SendTransactionAction(
                transaction: reviewed.transaction, resolvedNetwork: current.resolvedNetwork,
                walletId: current.walletId, account: current.account
            ))
        case (.addEthereumChain(let current), .addEthereumChain(let reviewed)):
            guard networkDefinitionMatches(current.chainToAdd, reviewed.chainToAdd) else { return nil }
            return reviewedAction
        default:
            return nil
        }
    }

    fileprivate static func transactionIntentMatches(_ left: Transaction, _ right: Transaction) -> Bool {
        left.from == right.from && left.to == right.to && left.value == right.value &&
            left.data == right.data && left.accessList == right.accessList && left.feeIntent == right.feeIntent
    }

    fileprivate static func networkDefinitionMatches(
        _ left: EthereumNetworkFromDapp,
        _ right: EthereumNetworkFromDapp
    ) -> Bool {
        left.chainId == right.chainId && left.rpcUrls == right.rpcUrls &&
            left.blockExplorerUrls == right.blockExplorerUrls && left.chainName == right.chainName &&
            left.nativeCurrency.decimals == right.nativeCurrency.decimals &&
            left.nativeCurrency.name == right.nativeCurrency.name &&
            left.nativeCurrency.symbol == right.nativeCurrency.symbol
    }

    fileprivate static func messagePayloadMatches(
        _ left: SignMessageAction.Payload,
        _ right: SignMessageAction.Payload
    ) -> Bool {
        switch (left, right) {
        case (.ethereumMessage(let left), .ethereumMessage(let right)),
             (.ethereumPersonalMessage(let left), .ethereumPersonalMessage(let right)),
             (.solanaMessage(let left), .solanaMessage(let right)):
            return left == right
        case (.ethereumTypedData(let left), .ethereumTypedData(let right)):
            return left == right
        case (.solanaTransaction(let left), .solanaTransaction(let right)):
            return left.messageData == right.messageData
        case (.solanaTransactions(let left), .solanaTransactions(let right)):
            return left.map(\.messageData) == right.map(\.messageData)
        case (.solanaLegacyBroadcast(let left, let leftOptions),
              .solanaLegacyBroadcast(let right, let rightOptions)):
            return left.preparedMessage.messageData == right.preparedMessage.messageData &&
                optionsMatch(leftOptions, rightOptions)
        case (.solanaSerializedBroadcast(let left, let leftOptions),
              .solanaSerializedBroadcast(let right, let rightOptions)):
            return left.preparedMessage.messageData == right.preparedMessage.messageData &&
                optionsMatch(leftOptions, rightOptions)
        default:
            return false
        }
    }

    private static func optionsMatch(_ left: Solana.PreparedSendOptions, _ right: Solana.PreparedSendOptions) -> Bool {
        left.clusterHint == right.clusterHint && left.preflightCommitment == right.preflightCommitment &&
            left.maxRetries == right.maxRetries && left.minContextSlot == right.minContextSlot &&
            left.confirmationCommitment == right.confirmationCommitment
    }

    private static func resolveMessagePayload(
        _ payload: SignMessageAction.Payload,
        cluster: Solana.Cluster?
    ) -> ApprovedWalletSigningOperation.Payload? {
        switch (payload, cluster) {
        case (.solanaLegacyBroadcast(let transaction, let options), let cluster?):
            return .solanaLegacyBroadcast(transaction, options, cluster)
        case (.solanaSerializedBroadcast(let transaction, let options), let cluster?):
            return .solanaSerializedBroadcast(transaction, options, cluster)
        case (.ethereumMessage(let data), nil):
            return .ethereumMessage(data)
        case (.ethereumPersonalMessage(let data), nil):
            return .ethereumPersonalMessage(data)
        case (.ethereumTypedData(let data), nil):
            return .ethereumTypedData(data)
        case (.solanaMessage(let data), nil):
            return .solanaMessage(data)
        case (.solanaTransaction(let transaction), nil):
            return .solanaTransaction(transaction)
        case (.solanaTransactions(let transactions), nil):
            return .solanaTransactions(transactions)
        default:
            return nil
        }
    }

    static func resolveSelection(
        action: SelectAccountAction,
        selection: DappApprovalDecision.AccountSelection,
        accounts: [SpecificWalletAccount],
        networkResolver: (String) -> EthereumNetwork?
    ) -> Selection? {
        var resolvedAccounts = [SpecificWalletAccount]()
        var selectedCoins = Set<WalletCoin>()
        for identity in selection.accounts {
            guard identity.isValid,
                  action.coinType == nil || action.coinType == identity.coin,
                  selectedCoins.insert(identity.coin).inserted else { return nil }
            let matches = accounts.filter {
                WalletAccountDescriptor(walletID: $0.walletId, account: $0.account) == identity
            }
            guard matches.count == 1 else { return nil }
            resolvedAccounts.append(matches[0])
        }
        let chainID = selection.ethereumChainID ?? action.network?.chainIdHexString
        let network = chainID.flatMap(networkResolver)
        if resolvedAccounts.isEmpty {
            guard !action.initiallyConnectedProviders.isEmpty else { return nil }
        } else {
            guard chainID == nil || network != nil,
                  !resolvedAccounts.contains(where: { $0.account.coin == .ethereum }) ||
                    network != nil else { return nil }
        }
        return Selection(accounts: resolvedAccounts, network: network)
    }
}
