// ∅ 2026 lil org

import Foundation

struct PopupApprovalState {
    enum State: String {
        case review, authenticating, working, error, missing

        init(_ state: PopupRequestSession.State) {
            switch state {
            case .review: self = .review
            case .authenticating: self = .authenticating
            case .working: self = .working
            case .error: self = .error
            }
        }
    }

    enum Action: String {
        case approve, reject, retry, editTransaction, setTransactionSpeed, resolveApprovalAlert
    }

    let id: Int
    let state: State
    var actions: [Action] = []
    var host: String?
    var error: String?
    var review: [String: Any]?
    var editsError: Bool?

    var json: [String: Any] {
        var response: [String: Any] = [
            "id": id,
            "state": state.rawValue,
            "actions": actions.map(\.rawValue),
        ]
        if let host, !host.isEmpty { response["host"] = host }
        response["error"] = error
        if state == .review { response["review"] = review }
        response["editsError"] = editsError
        return response
    }
}

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

        let responseIsRejectable = (response["actions"] as? [String])?
            .contains(PopupApprovalState.Action.reject.rawValue) == true
        var fallback = errorState(
            id: request.id,
            actions: responseIsRejectable ? [.reject] : [.retry],
            error: Strings.somethingWentWrong
        )
        if let host = response["host"] as? String, !host.isEmpty {
            var withHost = fallback
            withHost["host"] = host
            if isWithinResponseLimit(withHost) {
                fallback = withHost
            }
        }
        return fallback
    }

    nonisolated static func errorState(
        id: Int,
        actions: [PopupApprovalState.Action] = [.retry],
        host: String? = nil,
        error: String
    ) -> [String: Any] {
        return PopupApprovalState(
            id: id,
            state: .error,
            actions: actions,
            host: host,
            error: error
        ).json
    }

    nonisolated private static func returnsApprovalState(
        _ command: InternalSafariRequest.PopupCommand
    ) -> Bool {
        switch command {
        case .getApprovalState, .retryApproval, .applyTransactionEdits, .resolveApprovalAlert:
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
        guard var review = response["review"] as? [String: Any] else { return response }
        review["iconURL"] = nil
        if var account = review["account"] as? [String: Any] {
            account["icon"] = nil
            review["account"] = account
        }
        if var accounts = review["accounts"] as? [[String: Any]] {
            for index in accounts.indices {
                accounts[index]["icon"] = nil
            }
            review["accounts"] = accounts
        }
        response["review"] = review
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
        state: PopupRequestSession.State,
        host: String? = nil
    ) -> [String: Any] {
        return PopupApprovalState(id: id, state: .init(state), host: host).json
    }

    func missingState(id: Int) -> [String: Any] {
        return PopupApprovalState(id: id, state: .missing).json
    }

    func secureSetupRequiredState(id: Int, host: String) -> [String: Any] {
        return Self.errorState(
            id: id,
            host: host,
            error: Strings.secureApprovalSetupRequired
        )
    }

    func approvalState(
        for session: PopupRequestSession,
        action: DappRequestAction,
        transactionMutationAllowed: Bool,
        editsError: Bool? = nil
    ) -> [String: Any] {
        guard session.state == .review else {
            return state(id: session.handle.id, state: session.state, host: session.request.host)
        }
        var review: [String: Any] = [
            "reviewToken": session.reviewToken.uuidString.lowercased(),
            "kind": kind(for: action).rawValue,
            "title": title(for: action),
        ]
        var actions: [PopupApprovalState.Action] = [.approve, .reject]
        var error = session.errorText
        if let favicon = session.request.favicon {
            review["iconURL"] = favicon
        }
        switch action {
        case .selectAccount(let action), .switchAccount(let action):
            addSelectAccountState(
                &review,
                action: action,
                walletAccess: session.walletAccess
            )
        case .approveMessage(let action):
            addSignMessageState(&review, action: action)
        case .approveTransaction(let action):
            actions = [.reject]
            if let transaction = session.transaction {
                let snapshot = transaction.snapshot
                if snapshot.canApprove { actions.insert(.approve, at: 0) }
                if transactionMutationAllowed {
                    if snapshot.canEdit { actions.append(.editTransaction) }
                    if snapshot.allowsMutation && snapshot.transaction.feeBasisBaseFeePerGas != nil {
                        actions.append(.setTransactionSpeed)
                    }
                    if transaction.activeAlert != nil { actions.append(.resolveApprovalAlert) }
                }
            }
            addTransactionState(
                &review,
                session: session,
                action: action,
                mutationAllowed: transactionMutationAllowed,
                error: &error
            )
        case .addEthereumChain(let action):
            review["chainName"] = action.chainToAdd.chainName
            review["rpcURL"] = action.chainToAdd.defaultRpcUrl
        }
        return PopupApprovalState(
            id: session.handle.id,
            state: .review,
            actions: actions,
            host: session.request.host,
            error: error,
            review: review,
            editsError: editsError
        ).json
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
        if let clusterSelection = action.solanaClusterOptions {
            let effectiveCluster = clusterSelection.suggestedCluster
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
        mutationAllowed: Bool,
        error: inout String?
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
        state["slider"] = [
            "visible": chain.isEthMainnet && transactionSession.hasGasSpeedInfo,
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
                error = message.isEmpty
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
