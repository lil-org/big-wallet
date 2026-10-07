// ∅ 2026 lil org

import Foundation
import Synchronization

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

    var signingAccount: WalletAccountDescriptor? {
        switch self {
        case .message(let approval): return approval.approvedAccount
        case .transaction(let execution): return execution.approvedAccount
        case .accountSelection, .addEthereumChain: return nil
        }
    }
}

@MainActor
final class ApprovalReview {
    private enum State { case open, accepted, invalidated }

    let intent: BoundApprovalIntent
    private var state = State.open

    var binding: ExtensionBridge.RequestBinding { intent.binding }
    var request: SafariRequest { binding.request }
    var action: DappRequestAction { intent.action }

    init(intent: BoundApprovalIntent) {
        self.intent = intent
    }

    func renewed() -> ApprovalReview {
        ApprovalReview(intent: intent)
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
        return ReviewConsent(intent: intent, decision: decision, approvedAt: approvedAt, nativeReceipt: nativeReceipt)
    }

}

fileprivate final class ConsentAuthorizationUse: Sendable {
    private let consumed = Mutex(false)

    var isAvailable: Bool { consumed.withLock { !$0 } }

    func consume() -> Bool {
        consumed.withLock { consumed in
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

struct ApprovalResolutionContext: Sendable {
    let accounts: [SpecificWalletAccount]
    let selectionNetwork: EthereumNetwork?
    let transactionNetwork: ResolvedEthereumNetwork?

    init(
        accounts: [SpecificWalletAccount],
        selectionNetwork: EthereumNetwork? = nil,
        transactionNetwork: ResolvedEthereumNetwork? = nil
    ) {
        self.accounts = accounts
        self.selectionNetwork = selectionNetwork
        self.transactionNetwork = transactionNetwork
    }
}

struct ReviewConsent: Sendable {
    let intent: BoundApprovalIntent
    private let authorizationUse: ConsentAuthorizationUse
    let decision: DappApprovalDecision
    let approvedAt: Date
    let nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?

    fileprivate init(
        intent: BoundApprovalIntent,
        decision: DappApprovalDecision,
        approvedAt: Date,
        nativeReceipt: ExtensionBridge.NativeDeliveryReceipt?
    ) {
        self.intent = intent
        authorizationUse = ConsentAuthorizationUse()
        self.decision = decision
        self.approvedAt = approvedAt
        self.nativeReceipt = nativeReceipt
    }

    var binding: ExtensionBridge.RequestBinding { intent.binding }
    var request: SafariRequest { binding.request }
    var authorizationIsAvailable: Bool { authorizationUse.isAvailable }

    func sharesAuthorization(with other: ReviewConsent) -> Bool {
        authorizationUse === other.authorizationUse
    }

    func invalidateAuthorization() {
        _ = consumeAuthorization()
    }

    fileprivate func consumeAuthorization() -> Bool {
        authorizationUse.consume()
    }

    @MainActor
    func resolve(
        context: ApprovalResolutionContext
    ) -> Result<ResolvedDappApproval, DappApprovalValidator.Failure> {
        DappApprovalValidator.resolve(
            action: intent.action, decision: decision, context: context
        ).map { approval in
            ResolvedDappApproval(consent: self, approval: approval)
        }
    }

}

struct ResolvedDappApproval: Sendable {
    private let consent: ReviewConsent
    let approval: DappApprovalValidator.Approval

    var binding: ExtensionBridge.RequestBinding { consent.binding }
    var request: SafariRequest { consent.request }
    var nativeReceipt: ExtensionBridge.NativeDeliveryReceipt? { consent.nativeReceipt }
    var approvedAt: Date { consent.approvedAt }

    fileprivate init(
        consent: ReviewConsent,
        approval: DappApprovalValidator.Approval
    ) {
        self.consent = consent
        self.approval = approval
    }

    func consumeAuthorization() -> Bool {
        consent.consumeAuthorization()
    }

    func sharesAuthorization(with consent: ReviewConsent) -> Bool {
        self.consent.sharesAuthorization(with: consent)
    }
}

@MainActor
enum DappApprovalResolver {
    static func resolve(
        _ consent: ReviewConsent,
        refreshWalletCatalog: @MainActor () async -> WalletReviewCatalog?,
        networkResolver: (Int) -> ApprovalNetworkResolution = { NetworkResolver.main.approvalResolution(chainId: $0) },
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> DurableApprovalExecutor.Resolution {
        guard !Task.isCancelled, isCurrent(), consent.authorizationIsAvailable else { return .abandon }
        if case .addEthereumChain(let action) = consent.intent.action {
            guard let chainID = Int(hexString: action.chainToAdd.chainId), chainID > 0 else {
                return .immediate(.failure(.internalError))
            }
            let network: EthereumNetworkResolution
            switch networkResolver(chainID) {
            case .resolved(let resolved): network = .resolved(resolved)
            case .missing: network = .unknown
            case .unavailable: return .reviewRequired
            }
            if let immediate = EthereumDappRequestProcessor.chainAdditionResolution(
                action.chainToAdd, networkResolver: { _ in network }
            ) {
                return .immediate(immediate)
            }
            return resolve(consent, context: .init(accounts: []))
        }

        let catalog = await refreshWalletCatalog()
        guard !Task.isCancelled, isCurrent(), consent.authorizationIsAvailable else { return .abandon }
        guard let catalog else { return .reviewRequired }
        if let account = consent.intent.action.signingAccount,
           let resolution = signingAccountResolution(account, request: consent.request, catalog: catalog) {
            return resolution
        }

        let selectionNetwork: EthereumNetwork?
        let transactionNetwork: ResolvedEthereumNetwork?
        switch (consent.intent.action, consent.decision) {
        case (.selectAccount(let action), .accountSelection(let selection)),
             (.switchAccount(let action), .accountSelection(let selection)):
            if selection.accounts.contains(where: { catalog.availability(of: $0) == .removed }) {
                return .immediate(.failure(.internalError))
            }
            if selection.accounts.contains(where: { catalog.availability(of: $0) == .unavailable }) {
                return .reviewRequired
            }
            if !selection.accounts.isEmpty,
               let chainID = selection.ethereumChainID ?? action.network?.chainIdHexString {
                guard let value = Int(hexString: chainID), value > 0 else {
                    return .immediate(.failure(.internalError))
                }
                switch networkResolver(value) {
                case .resolved(let network): selectionNetwork = network.network
                case .missing: return .immediate(.failure(.internalError))
                case .unavailable: return .reviewRequired
                }
            } else {
                selectionNetwork = nil
            }
            transactionNetwork = nil
        case (.approveTransaction(let action), _):
            switch networkResolver(action.chain.chainId) {
            case .resolved(let network): transactionNetwork = network
            case .missing: return .immediate(.failure(.internalError))
            case .unavailable: return .reviewRequired
            }
            selectionNetwork = nil
        default:
            selectionNetwork = nil
            transactionNetwork = nil
        }
        guard !Task.isCancelled, isCurrent(), consent.authorizationIsAvailable else { return .abandon }
        return resolve(consent, context: .init(
            accounts: catalog.orderedAccounts,
            selectionNetwork: selectionNetwork,
            transactionNetwork: transactionNetwork
        ))
    }

    static func signingAccountResolution(
        _ account: WalletAccountDescriptor,
        request: SafariRequest,
        catalog: WalletReviewCatalog
    ) -> DurableApprovalExecutor.Resolution? {
        switch catalog.availability(of: account) {
        case .available: return nil
        case .unavailable: return .reviewRequired
        case .removed: return .immediate(missingSigningAccountResolution(for: request))
        }
    }

    static func missingSigningAccountResolution(for request: SafariRequest) -> ImmediateResolution {
        switch request.body {
        case .ethereum(let body):
            return body.method == .signTransaction
                ? staleResolution
                : .failure(.init(message: Strings.somethingWentWrong))
        case .solana(let body):
            return .solanaAuthorizationDenied(publicKey: body.publicKey)
        case .unknown:
            return .failure(.internalError)
        }
    }

    private static func resolve(
        _ consent: ReviewConsent,
        context: ApprovalResolutionContext
    ) -> DurableApprovalExecutor.Resolution {
        switch consent.resolve(context: context) {
        case .success(let approval): return .approved(approval)
        case .failure(.accountUnavailable): return .immediate(missingSigningAccountResolution(for: consent.request))
        case .failure(.staleTransaction), .failure(.staleAccount): return .immediate(staleResolution)
        case .failure(.invalidDecision): return .immediate(.failure(.internalError))
        }
    }

    private static var staleResolution: ImmediateResolution {
        .failure(ProviderResponseError(message: Strings.providerNotReady, code: 4100))
    }
}

enum DappApprovalValidator {

    struct Selection: Sendable {
        let accounts: [SpecificWalletAccount]
        let network: EthereumNetwork?
    }

    struct Approval: Sendable {
        enum Kind: Sendable {
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
        case accountUnavailable
        case invalidDecision
        case staleTransaction
        case staleAccount
    }

    static func resolve(
        action: DappRequestAction,
        decision: DappApprovalDecision,
        context: ApprovalResolutionContext
    ) -> Result<Approval, Failure> {
        if let approvedAccount = action.signingAccount {
            guard context.accounts.contains(where: {
                approvedAccount.matches(walletID: $0.walletId, account: $0.account)
            }) else { return .failure(.accountUnavailable) }
            guard decision.signingAccount == approvedAccount else {
                return .failure(.staleAccount)
            }
        }
        switch (action, decision) {
        case (.selectAccount(let action), .accountSelection(let selection)),
             (.switchAccount(let action), .accountSelection(let selection)):
            guard let resolved = resolveSelection(
                action: action, selection: selection,
                accounts: context.accounts, network: context.selectionNetwork
            ) else { return .failure(.invalidDecision) }
            return .success(Approval(.accountSelection(action, resolved)))
        case (.approveMessage(let action), .message(let approval)):
            guard let payload = resolveMessagePayload(action.payload, cluster: approval.solanaCluster) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(approvedAccount: approval.approvedAccount, payload: payload)))
        case (.approveTransaction(let action), .transaction(let execution)):
            guard let currentNetwork = context.transactionNetwork,
                  execution.isApplicable(to: action),
                  DappApprovalDecision.NetworkIdentity(currentNetwork) == execution.reviewedNetwork else {
                return .failure(.staleTransaction)
            }
            let transaction = execution.applyingValidatedFields(to: action.transaction)
            guard transaction.isReadyForApproval(on: currentNetwork.network) else {
                return .failure(.invalidDecision)
            }
            return .success(Approval(.signing(
                approvedAccount: execution.approvedAccount,
                payload: .ethereumTransaction(transaction, currentNetwork)
            )))
        case (.addEthereumChain(let action), .addEthereumChain):
            return .success(Approval(.addEthereumChain(action)))
        default:
            return .failure(.invalidDecision)
        }
    }

    static func resolveMessagePayload(
        _ payload: SignMessageAction.Payload,
        cluster: Solana.Cluster?
    ) -> ApprovedWalletSigningOperation.Payload? {
        switch (payload, cluster) {
        case (.solanaLegacyBroadcast(let transaction, let options), let cluster?):
            return .solanaLegacyBroadcast(transaction, options, cluster)
        case (.solanaSerializedBroadcast(let transaction, let options), let cluster?):
            return .solanaSerializedBroadcast(transaction, options, cluster)
        case (.signature(let payload), nil):
            return .signature(payload)
        default:
            return nil
        }
    }

    static func resolveSelection(
        action: SelectAccountAction,
        selection: DappApprovalDecision.AccountSelection,
        accounts: [SpecificWalletAccount],
        network: EthereumNetwork?
    ) -> Selection? {
        guard let resolvedAccounts = resolveSelectionAccounts(
            action: action, selection: selection, accounts: accounts
        ) else { return nil }
        let chainID = selection.ethereumChainID ?? action.network?.chainIdHexString
        if !resolvedAccounts.isEmpty {
            guard chainID == nil || network != nil,
                  !resolvedAccounts.contains(where: { $0.account.coin == .ethereum }) ||
                    network != nil else { return nil }
        }
        return Selection(accounts: resolvedAccounts, network: network)
    }

    static func resolveSelectionAccounts(
        action: SelectAccountAction,
        selection: DappApprovalDecision.AccountSelection,
        accounts: [SpecificWalletAccount]
    ) -> [SpecificWalletAccount]? {
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
        if resolvedAccounts.isEmpty {
            guard !action.initiallyConnectedProviders.isEmpty else { return nil }
        }
        return resolvedAccounts
    }
}
