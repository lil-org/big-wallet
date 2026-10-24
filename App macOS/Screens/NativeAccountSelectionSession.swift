import Cocoa

enum NativeAccountSelectionMode {
    case selectAccount, switchAccount
}

@MainActor
final class NativeAccountSelectionSession {
    let review: NativeApprovalReview
    let coinType: WalletCoin?
    var selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    let mode: NativeAccountSelectionMode
    var network: EthereumNetwork?

    private let completion: (
        [SpecificWalletAccount]?,
        EthereumNetwork?
    ) -> Void
    private(set) var hasCompleted = false

    init(
        action: SelectAccountAction,
        mode: NativeAccountSelectionMode,
        review: NativeApprovalReview,
        completion: @escaping (
            [SpecificWalletAccount]?,
            EthereumNetwork?
        ) -> Void
    ) {
        self.review = review
        coinType = action.coinType
        selectedAccounts = action.selectedAccounts
        initiallyConnectedProviders = action.initiallyConnectedProviders
        self.mode = mode
        network = action.network ?? Networks.ethereum
        self.completion = completion
    }

    var canSelectEthereumNetwork: Bool {
        if let coinType {
            return coinType == .ethereum
        }
        return initiallyConnectedProviders.contains(.ethereum) ||
            selectedAccounts.contains { $0.account.coin == .ethereum }
    }

    func canSubmitSelection() -> Bool {
        guard !selectedAccounts.isEmpty else { return false }
        let needsEthereumNetwork = selectedAccounts.contains {
            $0.account.coin == .ethereum
        }
        return !needsEthereumNetwork || network != nil
    }

    func complete(
        accounts: [SpecificWalletAccount]?,
        beforeCompletion: () -> Void = {}
    ) {
        guard review.isActive, !hasCompleted else { return }
        hasCompleted = true
        beforeCompletion()
        guard review.isActive else { return }
        completion(accounts, network)
    }
}
