// ∅ 2026 lil org

import Foundation

struct Strings {
    
    static let sendTransaction = loc("Send Transaction")
    static let signMessage = loc("Sign Message")
    static let signPersonalMessage = loc("Sign Personal Message")
    static let signTypedData = loc("Sign Typed Data")
    static let cancel = loc("Cancel")
    static let ok = loc("OK")
    static let apply = loc("Apply")
    static let somethingWentWrong = loc("Something went wrong")
    static let failedToSend = loc("Failed to send")
    static let failedToSign = loc("Failed to sign")
    static let enterWallet = loc("Enter Wallet")
    static let enableSafariExtension = loc("Enable Safari Extension")
    static let dropUsALine = loc("Mail")
    static let start = loc("Start")
    static let removeAccount = loc("Remove Account")
    static let removeWallet = loc("Remove Wallet")
    static let showPrivateKey = loc("Show Private Key")
    static let showSecretWords = loc("Show Secret Words")
    static let password = loc("Password")
    static let enterKeystorePassword = loc("Enter Keystore Password")
    static let importWalletTextFieldPlaceholder = loc("Options:\n\n• Private key\n• Secret words\n• Keystore")
    static let failedToImportWallet = loc("Failed to import wallet")
    static let welcomeScreenText = loc("Sign crypto\ntransactions\nin Safari")
    static let createPassword = loc("Create Password")
    static let repeatPassword = loc("Repeat Password")
    static let enterPassword = loc("Enter Password")
    static let copyAddress = loc("Copy Address")
    static let viewOn = loc("View on")
    static let viewOnSolanaExplorer = loc("View on Solana explorer")
    static let testnets = loc("Testnets")
    static let backUpNewWallet = loc("Back up new wallet")
    static let youWillSeeSecretWords = loc("You will see 12 secret words")
    static let removedWalletsCantBeRecovered = loc("Removed wallets can't be recovered")
    static let removeAnyway = loc("Remove anyway")
    static let iUnderstandTheRisks = loc("I understand the risks")
    static let privateKey = loc("Private Key")
    static let secretWords = loc("Secret Words")
    static let copy = loc("Copy")
    static let canceled = loc("Canceled")
    static let failedToVerify = loc("Failed to verify")
    static let wallets = loc("Wallets")
    static let selectAccount = loc("Select Account")
    static let selectNetwork = loc("Select Network")
    static let importWallet = loc("Import Wallet")
    static let addWallet = loc("Add Wallet")
    static let createNew = loc("Create New")
    static let importExisting = loc("Import")
    static let passwordDoesNotMatch = loc("Password does not match")
    static let toRemoveWallet = loc("to remove wallet")
    static let secretWordsGiveFullAccess = loc("Secret words give full access to your funds")
    static let privateKeyGivesFullAccess = loc("Private key gives full access to your funds")
    static let toShowSecretWords = loc("to show secret words")
    static let toShowPrivateKey = loc("to show private key")
    static let loading = loc("Loading")
    static let failedToLoad = loc("Failed to load")
    static let tryAgain = loc("Try Again")
    static let noData = loc("There is no data yet")
    static let refresh = loc("Refresh")
    static let nothingHere = loc("Nothing here")
    static let typeAtLeast = loc("Type at least 4 characters")
    static let unknownWebsite = loc("Unknown Website")
    static let calculating = loc("Calculating")
    static let approveTransaction = loc("Approve Transaction")
    static let multicoinWallet = loc("Multicoin Wallet")
    static let privateKeyWallets = loc("Private Key Wallets")
    static let editAccounts = loc("Edit Accounts")
    static let removingTheLastAccount = loc("Removing the last account removes the wallet as well")
    static let data = loc("Data")
    static let sendingTransaction = loc("Sending transaction")
    static let disconnect = loc("Disconnect")
    static let switchAccount = loc("Switch Account")
    static let rawSolanaTransactionWarning = loc("Raw Solana transaction. Big Wallet cannot display decoded instructions for this request. Only approve if you trust this website and expected this transaction.")
    static let suggestedByWebsite = loc("Suggested by website")
    static let alchemyRPC = loc("Alchemy RPC")
    static let publicRPC = loc("Public RPC")
    static let solanaBlockhashNotFound = loc("Solana blockhash not found. Check the selected network and try again.")
    static let solanaConfirmationTimedOut = loc("Solana transaction was sent, but confirmation timed out.")
    static let transactionSubmissionStatusUnknown = loc("Transaction submission status is unknown. Check the transaction ID before trying again.")
    static let unsupportedSolanaSendOptions = loc("Unsupported Solana send options")
    static let privateBrowsingUnsupported = loc("Big Wallet requests are unavailable in Private Browsing.")
    static let secureApprovalSetupRequired = loc("Open Big Wallet once to enable secure Safari approvals.")
    static let unrecognizedChainId = loc("Unrecognized chain ID")
    static let providerNotReady = loc("provider is not ready")
    static let done = loc("Done")
    static let pinned = loc("Pinned")
    static let mainnets = loc("Mainnets")
    static let nonce = loc("Nonce")
    static let gasPrice = loc("Gas price")
    static let maxPriorityFee = loc("Max priority fee")
    static let priorityFee = loc("Priority fee")
    static let maxFee = loc("Max fee")
    static let customNonce = loc("Custom nonce")
    static let customGasPrice = loc("Custom gas price")
    static let customMaxPriorityFee = loc("Custom max priority fee")
    static let customMaxFee = loc("Custom max fee")
    static let reset = loc("Reset")
    static let resetTo = loc("Reset to")
    static let transactionSpeedHint = loc("Adjust how quickly the transaction is likely to be included.")
    static let feesUpdated = loc("Network fees updated")
    static let feesUpdatedReview = loc("Network conditions changed. Review the updated fees, then approve again.")
    static let unsafeFees = loc("Fee settings need attention")
    static let unsafeFeesEdit = loc("Network conditions changed. Edit the fees before approving.")
    static let editFees = loc("Edit Fees")
    static let fee = loc("Fee")
    static let value = loc("Value")
    static let to = loc("To")
    static let connect = loc("Connect")
    static let paste = loc("Paste")
    static let getStarted = loc("Get Started")
    static let rateOnTheAppStore = loc("Rate on the App Store")
    static let addNetwork = loc("Add Network")
    static let customNetworks = loc("Custom Networks")
    static let setName = loc("Set Name")
    static let editName = loc("Edit Name")
    
    static let bigWallet = "Big Wallet"
    static let network = loc("Network")
    static let balance = loc("Balance")
    static let advanced = loc("Advanced")
    static let invalidValues = loc("Invalid values")
    static let noActivePage = loc("No active page")
    static let openBigWallet = loc("Open Big Wallet")
    static let notConnected = loc("Not connected")
    static let connectWallet = loc("Connect Wallet")
    static let addAccountToConnect = loc("Add %@ account to connect")
    static let queuePosition = loc("%1$@ of %2$@")

    static let viewOnGithub = "GitHub"
    static let viewOnX = "𝕏"
    static let gwei = "gwei"
    static let rpc = "RPC"

    // The Safari popup is HTML, so its chrome cannot read the string catalog itself.
    // These ride along with the first native response and are applied to the static labels.
    static var popup: [String: String] {
        return [
            "switchAccount": switchAccount,
            "network": network,
            "balance": balance,
            "fee": fee,
            "data": data,
            "advanced": advanced,
            "gasPrice": gasPrice + " (" + gwei + ")",
            "maxPriorityFee": maxPriorityFee + " (" + gwei + ")",
            "maxFee": maxFee + " (" + gwei + ")",
            "nonce": nonce,
            "invalidValues": invalidValues,
            "reset": reset,
            "apply": apply,
            "rpc": rpc,
            "cancel": cancel,
            "ok": ok,
            "noActivePage": noActivePage,
            "openBigWallet": openBigWallet,
            "notConnected": notConnected,
            "privateBrowsingUnsupported": privateBrowsingUnsupported,
            "somethingWentWrong": somethingWentWrong,
            "failedToLoad": failedToLoad,
            "refresh": refresh,
            "calculating": calculating.withEllipsis,
            "queuePosition": queuePosition,
        ]
    }
    
    private static func loc(_ string: String.LocalizationValue) -> String {
        return String(localized: string)
    }
    
}
