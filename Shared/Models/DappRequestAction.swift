// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

enum DappRequestAction {
    case none
    case justShowApp
    case switchAccount(SelectAccountAction)
    case selectAccount(SelectAccountAction)
    case approveMessage(SignMessageAction)
    case approveTransaction(SendTransactionAction)
}

struct SelectAccountAction {
    let peer: PeerMeta?
    let coinType: CoinType?
    var selectedAccounts: Set<SpecificWalletAccount>
    let initiallyConnectedProviders: Set<InpageProvider>
    var network: EthereumNetwork?
    let source: Source
    let completion: (EthereumNetwork?, [SpecificWalletAccount]?) -> Void
    
    enum Source {
        case walletConnect, safariExtension
    }
}

struct SignMessageAction {
    let provider: InpageProvider
    let subject: ApprovalSubject
    let account: Account
    let meta: String
    let peerMeta: PeerMeta
    let completion: (Bool) -> Void
}

struct SendTransactionAction {
    let provider: InpageProvider
    let transaction: Transaction
    let chain: EthereumNetwork
    let account: Account
    let peerMeta: PeerMeta
    let completion: (Transaction?) -> Void
}
