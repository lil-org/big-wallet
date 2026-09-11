// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupApprovalStatePresenter {

    nonisolated static let maximumResponseBytes = 512 * 1024
    private nonisolated static let maximumSelectableAccountIcons = 32

    private let iconDataURLs = NSCache<NSString, NSString>()

    init() {
        iconDataURLs.countLimit = 64
        iconDataURLs.totalCostLimit = 2 * 1024 * 1024
    }

    nonisolated static func boundedResponse(
        _ response: [String: Any],
        for request: InternalSafariRequest
    ) -> [String: Any] {
        if isWithinResponseLimit(response) {
            return response
        }
        let withoutImages = removingDecorativeImages(from: response)
        if isWithinResponseLimit(withoutImages) {
            return withoutImages
        }
        guard case .popup(let command) = request.command,
              returnsApprovalState(command) else {
            return ["status": "unavailable"]
        }

        let responseIsRejectable =
            response["state"] as? String == PopupRequestSession.State.review.rawValue ||
            response["canReject"] as? Bool == true
        var fallback = if responseIsRejectable {
            compactRejectableError(
                id: request.id,
                error: Strings.somethingWentWrong
            )
        } else {
            compactError(
                id: request.id,
                error: Strings.somethingWentWrong
            )
        }
        if let host = response["host"] as? String, !host.isEmpty {
            var withHost = fallback
            withHost["host"] = host
            if isWithinResponseLimit(withHost) {
                fallback = withHost
            }
        }
        return fallback
    }

    nonisolated static func compactError(
        id: Int,
        host: String? = nil,
        error: String
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": id,
            "state": PopupRequestSession.State.error.rawValue,
            "error": error,
        ]
        if let host, !host.isEmpty {
            response["host"] = host
        }
        return response
    }

    nonisolated static func compactRejectableError(
        id: Int,
        host: String? = nil,
        error: String
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": id,
            "state": PopupRequestSession.State.working.rawValue,
            "error": error,
            "canReject": true,
        ]
        if let host, !host.isEmpty {
            response["host"] = host
        }
        return response
    }

    nonisolated private static func returnsApprovalState(
        _ command: InternalSafariRequest.PopupCommand
    ) -> Bool {
        switch command {
        case .getApprovalState, .applyTransactionEdits, .resolveApprovalAlert:
            return true
        case .setTransactionSpeed:
            return true
        case .getPendingRequests, .approveRequest, .rejectRequest:
            return false
        }
    }

    nonisolated private static func isWithinResponseLimit(
        _ response: [String: Any]
    ) -> Bool {
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response) else {
            return false
        }
        return data.count <= maximumResponseBytes
    }

    nonisolated private static func removingDecorativeImages(
        from response: [String: Any]
    ) -> [String: Any] {
        var response = response
        response["iconURL"] = nil
        if var account = response["account"] as? [String: Any] {
            account["icon"] = nil
            response["account"] = account
        }
        if var accounts = response["accounts"] as? [[String: Any]] {
            for index in accounts.indices {
                accounts[index]["icon"] = nil
            }
            response["accounts"] = accounts
        }
        return response
    }

    func pendingResponse(
        requests: [[String: Any]] = [],
        completedResponses: [[String: Any]] = []
    ) -> [String: Any] {
        return [
            "requests": requests,
            "completedResponses": completedResponses,
            "strings": Strings.popup,
            "layoutDirection": layoutDirection,
        ]
    }

    func completedResponse(_ snapshot: ExtensionBridge.Snapshot) -> [String: Any] {
        return [
            "id": snapshot.handle.id,
            "host": snapshot.host,
            "configurationKey": snapshot.configurationKey,
            "requestToken": snapshot.handle.requestToken,
            "revisions": snapshot.revisions.json,
        ]
    }

    func pendingRequest(_ snapshot: ExtensionBridge.Snapshot) -> [String: Any] {
        return [
            "id": snapshot.handle.id,
            "host": snapshot.host,
            "receivedAt": snapshot.createdAt.timeIntervalSince1970,
            "sequence": snapshot.sequence,
            "requestToken": snapshot.handle.requestToken,
            "enqueueAttempt": snapshot.enqueueAttempt,
            "configurationKey": snapshot.configurationKey,
            "provider": snapshot.request?.provider.rawValue ??
                InpageProvider.unknown.rawValue,
            "revisions": snapshot.revisions.json,
        ]
    }

    func state(
        id: Int,
        state: PopupRequestSession.State
    ) -> [String: Any] {
        return ["id": id, "state": state.rawValue]
    }

    func missingState(id: Int) -> [String: Any] {
        return ["id": id, "state": "missing"]
    }

    func secureSetupRequiredState(id: Int, host: String) -> [String: Any] {
        return [
            "id": id,
            "state": PopupRequestSession.State.error.rawValue,
            "host": host,
            "error": Strings.secureApprovalSetupRequired,
            "secureSetupRequired": true,
        ]
    }

    func approvalState(
        for session: PopupRequestSession,
        action: DappRequestAction,
        transactionMutationAllowed: Bool
    ) -> [String: Any] {
        var state: [String: Any] = [
            "reviewToken": session.reviewToken.uuidString.lowercased(),
            "id": session.handle.id,
            "kind": kind(for: action).rawValue,
            "state": session.state.rawValue,
            "title": title(for: action),
            "host": session.request.host,
        ]
        if let errorText = session.errorText {
            state["error"] = errorText
        }
        if let favicon = session.request.favicon {
            state["iconURL"] = favicon
        }
        switch action {
        case .selectAccount(let action), .switchAccount(let action):
            addSelectAccountState(
                &state,
                action: action,
                walletAccess: session.walletAccess
            )
        case .approveMessage(let action):
            addSignMessageState(&state, action: action)
        case .approveTransaction(let action):
            addTransactionState(
                &state,
                session: session,
                action: action,
                mutationAllowed: transactionMutationAllowed
            )
        case .addEthereumChain(let action):
            state["chainName"] = action.chainToAdd.chainName
            state["rpcURL"] = action.chainToAdd.defaultRpcUrl
        }
        return state
    }

    static func transactionAlertMessage(alert: TransactionApprovalAlertIntent) -> String {
        return alert.presentation.message ?? ""
    }

    private var layoutDirection: String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: language).characterDirection == .rightToLeft
            ? "rtl"
            : "ltr"
    }

    private func kind(for action: DappRequestAction) -> PopupRequestSession.Kind {
        switch action {
        case .selectAccount:
            return .selectAccount
        case .switchAccount:
            return .switchAccount
        case .approveMessage:
            return .signMessage
        case .approveTransaction:
            return .sendTransaction
        case .addEthereumChain:
            return .addChain
        }
    }

    private func title(for action: DappRequestAction) -> String {
        switch action {
        case .selectAccount:
            return Strings.connectWallet
        case .switchAccount:
            return Strings.switchAccount
        case .approveMessage(let action):
            return action.subject.title
        case .approveTransaction:
            return Strings.sendTransaction
        case .addEthereumChain:
            return Strings.addNetwork
        }
    }

    private func addSelectAccountState(
        _ state: inout [String: Any],
        action: SelectAccountAction,
        walletAccess: WalletAccess?
    ) {
        let selected = action.selectedAccounts
        var accounts = [[String: Any]]()
        var hasEthereumCandidates = false
        for specific in walletAccess?.orderedAccounts ?? [] {
            let walletID = specific.walletId
            let account = specific.account
                if let coinType = action.coinType, account.coin != coinType {
                    continue
                }
                if account.coin == .ethereum {
                    hasEthereumCandidates = true
                }
                var item = accountModel(
                    walletId: walletID,
                    account: account,
                    includesIcon: accounts.count < Self.maximumSelectableAccountIcons
                )
                item["walletId"] = walletID
                item["address"] = account.address
                item["coin"] = account.coin.correspondingInpageProvider.rawValue
                item["derivationPath"] = account.derivationPath
                item["isSelected"] = selected.contains(specific)
                accounts.append(item)
        }
        state["accounts"] = accounts
        if accounts.isEmpty, let coinName = action.coinType?.name {
            state["emptyMessage"] = String(format: Strings.addAccountToConnect, coinName)
        }
        let canSelectNetwork = action.canSelectEthereumNetwork ||
            (action.coinType == nil && hasEthereumCandidates)
        state["canSelectNetwork"] = canSelectNetwork
        if canSelectNetwork {
            state["networks"] = networksList(selected: action.network)
        }
        state["allowsEmptySelection"] = !action.initiallyConnectedProviders.isEmpty
        if action.initiallyConnectedProviders.isEmpty {
            state["primaryTitle"] = Strings.connect
        }
    }

    private func addSignMessageState(
        _ state: inout [String: Any],
        action: SignMessageAction
    ) {
        state["meta"] = action.meta
        state["account"] = accountModel(walletId: action.walletId, account: action.account)
        if let clusterSelection = action.solanaClusterSelection {
            let effectiveCluster = clusterSelection.selectedCluster ??
                clusterSelection.suggestedCluster
            state["clusters"] = clusterSelection.clusters.map { cluster in
                return [
                    "value": cluster.rawValue,
                    "label": clusterSelection.description(for: cluster),
                    "isSelected": cluster == effectiveCluster,
                ] as [String: Any]
            }
            state["requiresClusterSelection"] = effectiveCluster == nil
        }
    }

    private func addTransactionState(
        _ state: inout [String: Any],
        session: PopupRequestSession,
        action: SendTransactionAction,
        mutationAllowed: Bool
    ) {
        guard let transactionSession = session.transaction else { return }
        let chain = action.chain
        let snapshot = transactionSession.snapshot
        let transaction = snapshot.transaction
        let price = PriceService.shared.forNetwork(chain)
        state["account"] = accountModel(walletId: action.walletId, account: action.account)
        state["networkName"] = chain.name
        if let balance = transactionSession.balance {
            state["balance"] = balance
        }
        if let value = transaction.valueWithSymbol(chain: chain, price: price, withLabel: true) {
            state["valueLine"] = value
        }
        state["feeLines"] = transaction.feeSummaryLines(chain: chain, price: price)
        if let interpretation = transaction.diplayDataInterpretation {
            state["dataInterpretation"] = interpretation
        }
        state["phase"] = snapshot.phase.rawValue
        state["canApprove"] = snapshot.canApprove && session.state == .review
        state["transactionMutationAllowed"] = mutationAllowed
        state["canEdit"] = snapshot.canEdit && mutationAllowed
        state["slider"] = [
            "visible": chain.isEthMainnet && transactionSession.hasGasSpeedInfo,
            "enabled": snapshot.allowsMutation &&
                mutationAllowed &&
                transaction.feeBasisBaseFeePerGas != nil,
            "position": transactionSession.gasSliderPosition(for: transaction),
            "maximum": GasSpeedConfiguration.maximumSliderPosition,
        ] as [String: Any]
        state["editor"] = editorModel(
            transaction: transaction,
            suggestedFee: snapshot.latestWalletSuggestedFee
        )
        if let alert = transactionSession.activeAlert {
            let presentation = alert.presentation
            let message = Self.transactionAlertMessage(alert: alert.intent)
            if mutationAllowed {
                state["alert"] = [
                    "title": presentation.title,
                    "message": message,
                    "actions": presentation.actions.map {
                        ["title": $0.title, "action": $0.action.rawValue]
                    },
                ] as [String: Any]
            } else {
                state["error"] = message.isEmpty
                    ? presentation.title
                    : "\(presentation.title): \(message)"
            }
        }
        if transactionSession.editorRequestToken > 0 {
            state["editorRequestToken"] = transactionSession.editorRequestToken
        }
    }

    private func editorModel(
        transaction: Transaction,
        suggestedFee: PreparedTransactionFee?
    ) -> [String: Any] {
        let fields = transaction.editableFields
        var editor: [String: Any] = [
            "usesEIP1559": transaction.usesEIP1559Fees,
            "nonce": fields.nonce,
        ]
        if transaction.usesEIP1559Fees {
            editor["maxPriorityFeePerGasGwei"] = fields.maxPriorityFeePerGasGwei
            editor["maxFeePerGasGwei"] = fields.maxFeePerGasGwei
        } else {
            editor["gasPriceGwei"] = fields.gasPriceGwei
        }
        if let suggestedFee {
            switch suggestedFee {
            case .legacy(let gasPrice):
                editor["suggestedGasPriceGwei"] = Transaction.editableGwei(
                    fromWei: gasPrice
                ) ?? ""
            case .eip1559(let priorityFee, let maximumFee):
                editor["suggestedMaxPriorityFeePerGasGwei"] = Transaction.editableGwei(
                    fromWei: priorityFee
                ) ?? ""
                editor["suggestedMaxFeePerGasGwei"] = Transaction.editableGwei(
                    fromWei: maximumFee
                ) ?? ""
            }
        }
        return editor
    }

    private func accountModel(
        walletId: String,
        account: WalletAccount,
        includesIcon: Bool = true
    ) -> [String: Any] {
        var model: [String: Any] = [
            "name": account.nameOrCroppedAddress(walletId: walletId),
            "croppedAddress": account.croppedAddress,
        ]
        if includesIcon, let iconDataURL = iconDataURL(for: account) {
            model["icon"] = iconDataURL
        }
        return model
    }

    private func networksList(selected: EthereumNetwork?) -> [[String: Any]] {
        var seen = Set<Int>()
        var list = [[String: Any]]()
        var networks = Networks.ordered
        let customChainIds = Set(Networks.custom.map(\.chainId))
        if let selected,
           let selectedIndex = networks.firstIndex(where: {
               $0.chainId == selected.chainId
           }) {
            networks.insert(networks.remove(at: selectedIndex), at: 0)
        }
        for network in networks {
            guard seen.insert(network.chainId).inserted else { continue }
            list.append([
                "chainId": network.chainIdHexString,
                "name": network.name,
                "isCustom": customChainIds.contains(network.chainId),
                "isSelected": network.chainId == selected?.chainId,
            ])
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
