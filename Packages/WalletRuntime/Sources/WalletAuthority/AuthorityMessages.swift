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

enum AuthorityMessageContext {
    @TaskLocal static var current = AuthorityMessages.testingEnglish
}

enum AuthorityStrings {
    static var manualSwitchCapacityReached: String { AuthorityMessageContext.current[.manualSwitchCapacityReached] }
    static var addAccountToConnect: String { AuthorityMessageContext.current[.addAccountToConnect] }
    static var addNetwork: String { AuthorityMessageContext.current[.addNetwork] }
    static var approvalInterrupted: String { AuthorityMessageContext.current[.approvalInterrupted] }
    static var calculating: String { AuthorityMessageContext.current[.calculating] }
    static var cancel: String { AuthorityMessageContext.current[.cancel] }
    static var canceled: String { AuthorityMessageContext.current[.canceled] }
    static var connect: String { AuthorityMessageContext.current[.connect] }
    static var connectWallet: String { AuthorityMessageContext.current[.connectWallet] }
    static var data: String { AuthorityMessageContext.current[.data] }
    static var failedToLoad: String { AuthorityMessageContext.current[.failedToLoad] }
    static var failedToSend: String { AuthorityMessageContext.current[.failedToSend] }
    static var failedToSign: String { AuthorityMessageContext.current[.failedToSign] }
    static var failedToVerify: String { AuthorityMessageContext.current[.failedToVerify] }
    static var feesUpdated: String { AuthorityMessageContext.current[.feesUpdated] }
    static var feesUpdatedReview: String { AuthorityMessageContext.current[.feesUpdatedReview] }
    static var privateBrowsingUnsupported: String { AuthorityMessageContext.current[.privateBrowsingUnsupported] }
    static var providerNotReady: String { AuthorityMessageContext.current[.providerNotReady] }
    static var rawSolanaTransactionWarning: String { AuthorityMessageContext.current[.rawSolanaTransactionWarning] }
    static var secureApprovalSetupRequired: String { AuthorityMessageContext.current[.secureApprovalSetupRequired] }
    static var sendTransaction: String { AuthorityMessageContext.current[.sendTransaction] }
    static var solanaBlockhashNotFound: String { AuthorityMessageContext.current[.solanaBlockhashNotFound] }
    static var solanaConfirmationTimedOut: String { AuthorityMessageContext.current[.solanaConfirmationTimedOut] }
    static var somethingWentWrong: String { AuthorityMessageContext.current[.somethingWentWrong] }
    static var switchAccount: String { AuthorityMessageContext.current[.switchAccount] }
    static var transactionSubmissionStatusUnknown: String { AuthorityMessageContext.current[.transactionSubmissionStatusUnknown] }
    static var unrecognizedChainId: String { AuthorityMessageContext.current[.unrecognizedChainId] }
    static var unsafeFees: String { AuthorityMessageContext.current[.unsafeFees] }
    static var unsafeFeesEdit: String { AuthorityMessageContext.current[.unsafeFeesEdit] }
    static var unsupportedSolanaSendOptions: String { AuthorityMessageContext.current[.unsupportedSolanaSendOptions] }
}
