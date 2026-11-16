import Foundation

public struct AuthorityMessages: Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case manualSwitchCapacityReached
        case addAccountToConnect
        case addNetwork
        case approvalInterrupted
        case calculating
        case cancel
        case canceled
        case connect
        case connectWallet
        case data
        case failedToLoad
        case failedToSend
        case failedToSign
        case failedToVerify
        case feesUpdated
        case feesUpdatedReview
        case privateBrowsingUnsupported
        case providerNotReady
        case rawSolanaTransactionWarning
        case secureApprovalSetupRequired
        case sendTransaction
        case solanaBlockhashNotFound
        case solanaConfirmationTimedOut
        case somethingWentWrong
        case switchAccount
        case transactionSubmissionStatusUnknown
        case unrecognizedChainId
        case unsafeFees
        case unsafeFeesEdit
        case unsupportedSolanaSendOptions
    }

    private let values: [Key: String]

    public init(values: [Key: String]) {
        precondition(values.count == Key.allCases.count && Key.allCases.allSatisfy { values[$0] != nil })
        self.values = values
    }

    public subscript(key: Key) -> String {
        values[key]!
    }

    static let testingEnglish = AuthorityMessages(values: [
        .manualSwitchCapacityReached: "Too many account switches are pending. Finish one, then try again.",
        .addAccountToConnect: "Add %@ account to connect",
        .addNetwork: "Add Network",
        .approvalInterrupted: "Approval interrupted. Please try again from the website.",
        .calculating: "Calculating",
        .cancel: "Cancel",
        .canceled: "Canceled",
        .connect: "Connect",
        .connectWallet: "Connect Wallet",
        .data: "Data",
        .failedToLoad: "Failed to load",
        .failedToSend: "Failed to send",
        .failedToSign: "Failed to sign",
        .failedToVerify: "Failed to verify",
        .feesUpdated: "Network fees updated",
        .feesUpdatedReview: "Network conditions changed. Review the updated fees, then approve again.",
        .privateBrowsingUnsupported: "Big Wallet requests are unavailable in Private Browsing.",
        .providerNotReady: "provider is not ready",
        .rawSolanaTransactionWarning: "Raw Solana transaction. Big Wallet cannot display decoded instructions for this request. Only approve if you trust this website and expected this transaction.",
        .secureApprovalSetupRequired: "Safari approvals require a device passcode. Enable one in Settings if needed, then open Big Wallet and return to Safari to retry.",
        .sendTransaction: "Send Transaction",
        .solanaBlockhashNotFound: "Solana blockhash not found. Check the selected network and try again.",
        .solanaConfirmationTimedOut: "Solana transaction was sent, but confirmation timed out.",
        .somethingWentWrong: "Something went wrong",
        .switchAccount: "Switch Account",
        .transactionSubmissionStatusUnknown: "Transaction submission status is unknown. Check the transaction ID before trying again.",
        .unrecognizedChainId: "Unrecognized chain ID",
        .unsafeFees: "Fee settings need attention",
        .unsafeFeesEdit: "Network conditions changed. Edit the fees before approving.",
        .unsupportedSolanaSendOptions: "Unsupported Solana send options",
    ])
}
