// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupApprovalStatePresenter {

    private static let maximumSelectableAccountIcons = 32
    private let iconDataURLs = NSCache<NSString, NSString>()

    init() {
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
            strings: Strings.popup,
            layoutDirection: layoutDirection
        )
    }

    func completedResponse(_ snapshot: ExtensionBridge.Snapshot) -> PopupCompletedResponse {
        PopupCompletedResponse(
            id: snapshot.handle.id,
            host: snapshot.host,
            configurationKey: snapshot.configurationKey,
            requestToken: snapshot.handle.requestToken,
            revisions: snapshot.revisions
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
            provider: snapshot.request?.provider ?? .unknown,
            revisions: snapshot.revisions
        )
    }

    func state(
        id: Int,
        state: PopupRequestSession.State,
        host: String? = nil
    ) -> PopupApprovalState {
        let content: PopupApprovalState.Content
        switch state {
        case .authenticating: content = .authenticating
        case .working: content = .working
        case .error, .review:
            content = .error(message: Strings.failedToLoad, actions: [.retry])
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
            error: Strings.secureApprovalSetupRequired
        )
    }

    func approvalState(
        for session: PopupRequestSession,
        action: DappRequestAction,
        transactionMutationAllowed: Bool
    ) -> PopupApprovalState {
        guard session.state == .review else {
            return state(id: session.handle.id, state: session.state, host: session.request.host)
        }
        let content: PopupReview.Content
        var actions: [PopupApprovalState.Action] = [.approve, .reject]
        var error = session.errorText
        switch action {
        case .selectAccount(let action):
            content = .selectAccount(selectionReview(action: action, reviewCatalog: session.reviewCatalog))
        case .switchAccount(let action):
            content = .switchAccount(selectionReview(action: action, reviewCatalog: session.reviewCatalog))
        case .approveMessage(let action):
            content = .signMessage(messageReview(action: action))
        case .approveTransaction(let action):
            guard let transaction = session.transaction else {
                return Self.errorState(
                    id: session.handle.id,
                    actions: [.reject],
                    host: session.request.host,
                    error: Strings.failedToLoad
                )
            }
            actions = [.reject]
            let snapshot = transaction.snapshot
            if snapshot.canApprove { actions.insert(.approve, at: 0) }
            if transactionMutationAllowed {
                if snapshot.canEdit { actions.append(.editTransaction) }
                if snapshot.allowsMutation && snapshot.transaction.feeBasisBaseFeePerGas != nil {
                    actions.append(.setTransactionSpeed)
                }
                if transaction.activeAlert != nil { actions.append(.resolveApprovalAlert) }
            }
            content = .sendTransaction(transactionReview(
                transactionSession: transaction,
                action: action,
                mutationAllowed: transactionMutationAllowed,
                error: &error
            ))
        case .addEthereumChain(let action):
            content = .addChain(PopupChainReview(
                chainName: action.chainToAdd.chainName,
                rpcURL: action.chainToAdd.defaultRpcUrl
            ))
        }
        return PopupApprovalState(
            id: session.handle.id,
            host: session.request.host,
            content: .review(PopupReview(
                reviewToken: session.reviewToken,
                title: title(for: action),
                iconURL: session.request.favicon,
                content: content
            ), actions: actions, feedback: error)
        )
    }

    static func transactionAlertMessage(alert: TransactionApprovalAlertIntent) -> String {
        alert.presentation.message ?? ""
    }

    private var layoutDirection: PopupQueueResponse.LayoutDirection {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rtl : .ltr
    }

    private func title(for action: DappRequestAction) -> String {
        switch action {
        case .selectAccount: return Strings.connectWallet
        case .switchAccount: return Strings.switchAccount
        case .approveMessage(let action): return action.subject.title
        case .approveTransaction: return Strings.sendTransaction
        case .addEthereumChain: return Strings.addNetwork
        }
    }

    private func selectionReview(
        action: SelectAccountAction,
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
                isSelected: action.selectedAccounts.contains(specific)
            ))
        }
        let canSelectNetwork = action.canSelectEthereumNetwork ||
            (action.coinType == nil && hasEthereumCandidates)
        return PopupSelectionReview(
            accounts: accounts,
            networks: canSelectNetwork ? networksList(selected: action.network) : nil,
            canSelectNetwork: canSelectNetwork,
            allowsEmptySelection: !action.initiallyConnectedProviders.isEmpty,
            emptyMessage: accounts.isEmpty ? action.coinType.map {
                String(format: Strings.addAccountToConnect, $0.name)
            } : nil,
            primaryTitle: action.initiallyConnectedProviders.isEmpty ? Strings.connect : nil
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
                            label: selection.description(for: cluster),
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
        action: SendTransactionAction,
        mutationAllowed: Bool,
        error: inout String?
    ) -> PopupTransactionReview {
        let chain = action.chain
        let snapshot = transactionSession.snapshot
        let transaction = snapshot.transaction
        let price = PriceService.shared.forNetwork(chain)
        var alert: PopupTransactionAlert?
        if let activeAlert = transactionSession.activeAlert {
            let presentation = activeAlert.presentation
            let message = Self.transactionAlertMessage(alert: activeAlert.intent)
            if mutationAllowed {
                alert = PopupTransactionAlert(
                    title: presentation.title,
                    message: message,
                    actions: presentation.actions.map {
                        .init(title: $0.title, action: $0.action)
                    }
                )
            } else {
                error = message.isEmpty ? presentation.title : "\(presentation.title): \(message)"
            }
        }
        return PopupTransactionReview(
            account: accountModel(walletId: action.walletId, account: action.account),
            networkName: chain.name,
            balance: transactionSession.balance,
            valueLine: transaction.valueWithSymbol(chain: chain, price: price, withLabel: true),
            feeLines: transaction.feeSummaryLines(chain: chain, price: price),
            dataInterpretation: transaction.diplayDataInterpretation,
            phase: snapshot.phase,
            slider: PopupTransactionSlider(
                visible: chain.isEthMainnet && transactionSession.hasGasSpeedInfo,
                position: transactionSession.gasSliderPosition(for: transaction),
                maximum: GasSpeedConfiguration.maximumSliderPosition
            ),
            editor: editorModel(transaction: transaction, suggestedFee: snapshot.latestWalletSuggestedFee),
            alert: alert,
            editorRequestToken: transactionSession.editorRequestToken > 0
                ? transactionSession.editorRequestToken : nil
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
            name: account.nameOrCroppedAddress(walletId: walletId),
            croppedAddress: account.croppedAddress,
            icon: includesIcon ? iconDataURL(for: account) : nil
        )
    }

    private func networksList(selected: EthereumNetwork?) -> [PopupNetworkOption] {
        var seen = Set<Int>()
        var list = [PopupNetworkOption]()
        var networks = Networks.ordered
        let customChainIds = Set(Networks.custom.map(\.chainId))
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
        guard let image = account.image,
              let data = image.pngDataRepresentation else { return nil }
        let dataURL = "data:image/png;base64," + data.base64EncodedString()
        iconDataURLs.setObject(
            dataURL as NSString,
            forKey: key as NSString,
            cost: dataURL.utf8.count
        )
        return dataURL
    }
}
