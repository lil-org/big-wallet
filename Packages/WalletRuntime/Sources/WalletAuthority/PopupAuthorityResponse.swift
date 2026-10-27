import Foundation
import WalletDomain

@MainActor
public enum PopupAuthorityResponse {
    case queue(pending: [ExtensionBridge.Snapshot], completed: [ExtensionBridge.Snapshot])
    case queueUnavailable
    case command(status: PopupCommandStatus, state: PopupAuthorityState?)
}

@MainActor
public struct PopupAuthorityState {
    public enum Content {
        case review(PopupReviewSnapshot)
        case authenticating, working, missing
        case error(message: String, actions: [PopupApprovalState.RecoveryAction])
    }

    public let id: Int
    public let host: String?
    public let content: Content
    public let transactionMutationAllowed: Bool

    init(id: Int, host: String? = nil, content: Content, transactionMutationAllowed: Bool = false) {
        self.id = id
        self.host = host
        self.content = content
        self.transactionMutationAllowed = transactionMutationAllowed
    }
}

@MainActor
public struct PopupReviewSnapshot {
    public struct Selection {
        public let selectedAccounts: Set<SpecificWalletAccount>
        public let network: EthereumNetwork?
    }

    public struct PreparedTransaction {
        public let snapshot: TransactionApprovalSnapshot
        public let balance: String?
    }

    public enum Content {
        case selectAccount(action: SelectAccountAction, draft: Selection)
        case switchAccount(action: SelectAccountAction, draft: Selection)
        case approveMessage(SignMessageAction)
        case approveTransaction(action: SendTransactionAction, transaction: PreparedTransaction)
        case addEthereumChain(AddEthereumChainAction)
    }

    public let reviewToken: UUID
    public let content: Content
    public let reviewCatalog: WalletReviewCatalog?
    public let feedback: String?
}

extension PopupRequestSession {
    var publicPresentation: PopupAuthorityState.Content {
        switch presentation {
        case .authenticating: return .authenticating
        case .working: return .working
        case .error(let message): return .error(message: message, actions: [.retry, .reject])
        case .review(let review):
            let content: PopupReviewSnapshot.Content
            switch review.content {
            case .selectAccount(let action, let draft):
                content = .selectAccount(action: action, draft: .init(selectedAccounts: draft.selectedAccounts, network: draft.network))
            case .switchAccount(let action, let draft):
                content = .switchAccount(action: action, draft: .init(selectedAccounts: draft.selectedAccounts, network: draft.network))
            case .approveMessage(let action): content = .approveMessage(action)
            case .approveTransaction(let action, let transaction):
                content = .approveTransaction(action: action, transaction: .init(snapshot: transaction.snapshot, balance: transaction.balance))
            case .addEthereumChain(let action): content = .addEthereumChain(action)
            }
            return .review(PopupReviewSnapshot(reviewToken: review.reviewToken, content: content,
                reviewCatalog: review.reviewCatalog, feedback: review.feedback))
        }
    }
}
