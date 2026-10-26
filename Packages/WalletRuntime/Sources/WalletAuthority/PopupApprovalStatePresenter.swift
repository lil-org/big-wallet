import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

@MainActor
public final class PopupApprovalStatePresenter {
    public struct Environment: Sendable {
        let networks: @MainActor @Sendable () -> [EthereumNetwork]
        let customNetworks: @MainActor @Sendable () -> [EthereumNetwork]
        let price: @MainActor @Sendable (EthereumNetwork) -> Double?
        let accountName: @MainActor @Sendable (String, WalletAccount) -> String
        let icon: @MainActor @Sendable (WalletAccount) -> String?
        let transactionValue: @MainActor @Sendable (Transaction, EthereumNetwork, Double?) -> String?
        let transactionFeeLines: @MainActor @Sendable (Transaction, EthereumNetwork, Double?) -> [String]
        let transactionDataInterpretation: @MainActor @Sendable (Transaction) -> String?
        let solanaClusterDescription: @MainActor @Sendable (SolanaClusterOptions, Solana.Cluster) -> String
        let approvalSubjectTitle: @MainActor @Sendable (ApprovalSubject) -> String
        let transactionNotice: @MainActor @Sendable (TransactionReviewNotice) -> PopupTransactionNotice
        let popupStrings: [String: String]
        let layoutDirection: PopupQueueResponse.LayoutDirection

        public init(
            networks: @escaping @MainActor @Sendable () -> [EthereumNetwork],
            customNetworks: @escaping @MainActor @Sendable () -> [EthereumNetwork],
            price: @escaping @MainActor @Sendable (EthereumNetwork) -> Double?,
            accountName: @escaping @MainActor @Sendable (String, WalletAccount) -> String,
            icon: @escaping @MainActor @Sendable (WalletAccount) -> String?,
            transactionValue: @escaping @MainActor @Sendable (Transaction, EthereumNetwork, Double?) -> String?,
            transactionFeeLines: @escaping @MainActor @Sendable (Transaction, EthereumNetwork, Double?) -> [String],
            transactionDataInterpretation: @escaping @MainActor @Sendable (Transaction) -> String?,
            solanaClusterDescription: @escaping @MainActor @Sendable (SolanaClusterOptions, Solana.Cluster) -> String,
            approvalSubjectTitle: @escaping @MainActor @Sendable (ApprovalSubject) -> String,
            transactionNotice: @escaping @MainActor @Sendable (TransactionReviewNotice) -> PopupTransactionNotice,
            popupStrings: [String: String],
            layoutDirection: PopupQueueResponse.LayoutDirection
        ) {
            self.networks = networks
            self.customNetworks = customNetworks
            self.price = price
            self.accountName = accountName
            self.icon = icon
            self.transactionValue = transactionValue
            self.transactionFeeLines = transactionFeeLines
            self.transactionDataInterpretation = transactionDataInterpretation
            self.solanaClusterDescription = solanaClusterDescription
            self.approvalSubjectTitle = approvalSubjectTitle
            self.transactionNotice = transactionNotice
            self.popupStrings = popupStrings
            self.layoutDirection = layoutDirection
        }
    }

    private static let maximumSelectableAccountIcons = 32
    private let iconDataURLs = NSCache<NSString, NSString>()
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
        iconDataURLs.countLimit = 64
        iconDataURLs.totalCostLimit = 2 * 1024 * 1024
    }

    nonisolated static func errorState(
        id: Int,
        actions: [PopupApprovalState.RecoveryAction] = [.retry],
        host: String? = nil,
        error: String
    ) -> PopupApprovalState {
        PopupApprovalState(
            id: id,
            host: host,
            content: .error(message: error, actions: actions)
        )
    }

    func pendingResponse(
        requests: [PopupPendingRequest] = [],
        completedResponses: [PopupCompletedResponse] = []
    ) -> PopupQueueResponse {
        PopupQueueResponse(
            requests: requests,
            completedResponses: completedResponses,
            strings: environment.popupStrings,
            layoutDirection: environment.layoutDirection
        )
    }

    func completedResponse(_ snapshot: ExtensionBridge.Snapshot) -> PopupCompletedResponse {
        PopupCompletedResponse(
            id: snapshot.handle.id,
            host: snapshot.host,
            configurationKey: snapshot.configurationKey,
            requestToken: snapshot.handle.requestToken
        )
    }

    func pendingRequest(_ snapshot: ExtensionBridge.Snapshot) -> PopupPendingRequest {
        PopupPendingRequest(
            id: snapshot.handle.id,
            host: snapshot.host,
            receivedAt: snapshot.createdAt.timeIntervalSince1970,
            sequence: snapshot.sequence,
            requestToken: snapshot.handle.requestToken,
            enqueueAttempt: snapshot.enqueueAttempt,
            configurationKey: snapshot.configurationKey,
            provider: snapshot.request?.provider ?? .unknown
        )
    }

    func state(
        id: Int,
        host: String? = nil,
        presentation: PopupRequestSession.Presentation,
        transactionMutationAllowed: Bool = false
    ) -> PopupApprovalState {
        let content: PopupApprovalState.Content
        switch presentation {
        case .review(let review):
            return reviewState(
                id: id,
                host: host,
                review: review,
                transactionMutationAllowed: transactionMutationAllowed
            )
        case .authenticating: content = .authenticating
        case .working: content = .working
        case .error(let message):
            content = .error(message: message, actions: [.retry, .reject])
        }
        return PopupApprovalState(id: id, host: host, content: content)
    }

    func missingState(id: Int) -> PopupApprovalState {
        PopupApprovalState(id: id, content: .missing)
    }

    func secureSetupRequiredState(id: Int, host: String) -> PopupApprovalState {
        Self.errorState(
            id: id,
            actions: [.retry, .reject],
            host: host,
            error: AuthorityStrings.secureApprovalSetupRequired
        )
    }

    private func reviewState(
        id: Int,
        host: String?,
        review: PopupRequestSession.ReviewPresentation,
        transactionMutationAllowed: Bool
    ) -> PopupApprovalState {
        let content: PopupReview.Content
        var actions: [PopupApprovalState.Action] = [.approve, .reject]
        switch review.content {
        case .selectAccount(let action, let draft), .switchAccount(let action, let draft):
            content = .accountSelection(selectionReview(action: action, draft: draft, reviewCatalog: review.reviewCatalog))
        case .approveMessage(let action):
            content = .signMessage(messageReview(action: action))
        case .approveTransaction(let action, let transaction):
            actions = [.reject]
            let snapshot = transaction.snapshot
            if snapshot.canApprove { actions.insert(.approve, at: 0) }
            if transactionMutationAllowed {
                if snapshot.canEdit { actions.append(.editTransaction) }
                if snapshot.allowsMutation && snapshot.transaction.feeBasisBaseFeePerGas != nil {
                    actions.append(.setTransactionSpeed)
                }
                if snapshot.canRetryPreparation { actions.append(.retryTransaction) }
            }
            content = .sendTransaction(transactionReview(
                transactionSession: transaction,
                action: action
            ))
        case .addEthereumChain(let action):
            content = .addChain(PopupChainReview(
                chainName: action.chainToAdd.chainName,
                rpcURL: action.chainToAdd.defaultRpcUrl
            ))
        }
        return PopupApprovalState(
            id: id,
            host: host,
            content: .review(PopupReview(
                reviewToken: review.reviewToken,
                title: title(for: review.content),
                content: content
            ), actions: actions, feedback: review.feedback)
        )
    }

    func subjectTitle(_ subject: ApprovalSubject) -> String {
        environment.approvalSubjectTitle(subject)
    }

    private func title(for content: PopupRequestSession.ReviewContent) -> String {
        switch content {
        case .selectAccount: return AuthorityStrings.connectWallet
        case .switchAccount: return AuthorityStrings.switchAccount
        case .approveMessage(let action): return environment.approvalSubjectTitle(action.subject)
        case .approveTransaction: return AuthorityStrings.sendTransaction
        case .addEthereumChain: return AuthorityStrings.addNetwork
        }
    }

    private func selectionReview(
        action: SelectAccountAction,
        draft: PopupRequestSession.SelectionDraft,
        reviewCatalog: WalletReviewCatalog?
    ) -> PopupSelectionReview {
        var accounts = [PopupSelectableAccount]()
        var hasEthereumCandidates = false
        for specific in reviewCatalog?.orderedAccounts ?? [] {
            let account = specific.account
            if let coinType = action.coinType, account.coin != coinType { continue }
            if account.coin == .ethereum { hasEthereumCandidates = true }
            accounts.append(PopupSelectableAccount(
                display: accountModel(
                    walletId: specific.walletId,
                    account: account,
                    includesIcon: accounts.count < Self.maximumSelectableAccountIcons
                ),
                walletId: specific.walletId,
                address: account.address,
                coin: account.coin.correspondingInpageProvider,
                derivationPath: account.derivationPath,
                isSelected: draft.selectedAccounts.contains(specific)
            ))
        }
        let canSelectNetwork = action.coinType.map { $0 == .ethereum } ?? (
            action.initiallyConnectedProviders.contains(.ethereum) ||
                draft.selectedAccounts.contains { $0.account.coin == .ethereum } ||
                hasEthereumCandidates
        )
        return PopupSelectionReview(
            accounts: accounts,
            networks: canSelectNetwork ? networksList(selected: draft.network) : nil,
            canSelectNetwork: canSelectNetwork,
            allowsEmptySelection: !action.initiallyConnectedProviders.isEmpty,
            emptyMessage: accounts.isEmpty ? action.coinType.map {
                String(format: AuthorityStrings.addAccountToConnect, $0.name)
            } : nil,
            primaryTitle: action.initiallyConnectedProviders.isEmpty ? AuthorityStrings.connect : nil
        )
    }

    private func messageReview(action: SignMessageAction) -> PopupMessageReview {
        PopupMessageReview(
            meta: action.meta,
            account: accountModel(walletId: action.walletId, account: action.account),
            clusterSelection: action.solanaClusterOptions.map { selection in
                PopupClusterSelection(
                    clusters: selection.clusters.map { cluster in
                        PopupClusterOption(
                            value: cluster,
                            label: environment.solanaClusterDescription(selection, cluster),
                            isSelected: cluster == selection.suggestedCluster
                        )
                    },
                    requiresSelection: selection.suggestedCluster == nil
                )
            }
        )
    }

    private func transactionReview(
        transactionSession: PopupTransactionSession,
        action: SendTransactionAction
    ) -> PopupTransactionReview {
        let chain = action.chain
        let snapshot = transactionSession.snapshot
        let transaction = snapshot.transaction
        let price = environment.price(chain)
        var feeLines = environment.transactionFeeLines(transaction, chain, price)
        if snapshot.phase == .idle || snapshot.phase == .preparing {
            feeLines.append(AuthorityStrings.calculating.withEllipsis)
        }
        let canBackOffRefresh: Bool
        switch snapshot.phase {
        case .ready, .failed, .finished:
            canBackOffRefresh = true
        case .idle, .preparing, .editing, .reserved, .preflighting:
            canBackOffRefresh = false
        }
        return PopupTransactionReview(
            account: accountModel(walletId: action.walletId, account: action.account),
            networkName: chain.name,
            balance: transactionSession.balance,
            valueLine: environment.transactionValue(transaction, chain, price),
            feeLines: feeLines,
            dataInterpretation: environment.transactionDataInterpretation(transaction),
            canBackOffRefresh: canBackOffRefresh,
            slider: PopupTransactionSlider(
                visible: chain.isEthMainnet && snapshot.hasGasSpeedInfo,
                position: snapshot.gasSliderPosition,
                maximum: GasSpeedConfiguration.maximumSliderPosition
            ),
            editor: editorModel(transaction: transaction, suggestedFee: snapshot.latestWalletSuggestedFee),
            notice: snapshot.notice.map(environment.transactionNotice)
        )
    }

    private func editorModel(
        transaction: Transaction,
        suggestedFee: PreparedTransactionFee?
    ) -> PopupTransactionEditor {
        let fields = transaction.editableFields
        let fee: PopupTransactionEditor.Fee = transaction.usesEIP1559Fees
            ? .eip1559(maxPriorityFeePerGasGwei: fields.maxPriorityFeePerGasGwei, maxFeePerGasGwei: fields.maxFeePerGasGwei)
            : .legacy(gasPriceGwei: fields.gasPriceGwei)
        let suggested: PopupTransactionEditor.Fee? = suggestedFee.map {
            switch $0 {
            case .legacy(let gasPrice):
                return .legacy(gasPriceGwei: Transaction.editableGwei(fromWei: gasPrice) ?? "")
            case .eip1559(let priority, let maximum):
                return .eip1559(
                    maxPriorityFeePerGasGwei: Transaction.editableGwei(fromWei: priority) ?? "",
                    maxFeePerGasGwei: Transaction.editableGwei(fromWei: maximum) ?? ""
                )
            }
        }
        return .init(nonce: fields.nonce, fee: fee, suggestedFee: suggested)
    }

    private func accountModel(
        walletId: String,
        account: WalletAccount,
        includesIcon: Bool = true
    ) -> PopupDisplayAccount {
        PopupDisplayAccount(
            name: environment.accountName(walletId, account),
            croppedAddress: account.croppedAddress,
            icon: includesIcon ? iconDataURL(for: account) : nil
        )
    }

    private func networksList(selected: EthereumNetwork?) -> [PopupNetworkOption] {
        var seen = Set<Int>()
        var list = [PopupNetworkOption]()
        var networks = environment.networks()
        let customChainIds = Set(environment.customNetworks().map(\.chainId))
        if let selected,
           let selectedIndex = networks.firstIndex(where: { $0.chainId == selected.chainId }) {
            networks.insert(networks.remove(at: selectedIndex), at: 0)
        }
        for network in networks where seen.insert(network.chainId).inserted {
            list.append(PopupNetworkOption(
                chainId: network.chainIdHexString,
                name: network.name,
                isCustom: customChainIds.contains(network.chainId),
                isSelected: network.chainId == selected?.chainId
            ))
        }
        return list
    }

    private func iconDataURL(for account: WalletAccount) -> String? {
        let key = account.coin.correspondingInpageProvider.rawValue + "|" + account.address
        if let cached = iconDataURLs.object(forKey: key as NSString) {
            return cached as String
        }
        guard let dataURL = environment.icon(account) else { return nil }
        iconDataURLs.setObject(
            dataURL as NSString,
            forKey: key as NSString,
            cost: dataURL.utf8.count
        )
        return dataURL
    }
}

