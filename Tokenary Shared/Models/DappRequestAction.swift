// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

enum DappRequestAction {
    case none
    case justShowApp
    case selectAccount(SelectAccountAction)
    case approveMessage(SignMessageAction)
    case approveTransaction(SendTransactionAction)
}

struct SelectAccountAction {
    let provider: Web3Provider
    let completion: (EthereumChain?, TokenaryWallet?) -> Void
}

struct SignMessageAction {
    let provider: Web3Provider
    let subject: ApprovalSubject
    let address: String
    let meta: String
    let peerMeta: PeerMeta
    let completion: (Bool) -> Void
}

struct SendTransactionAction {
    let provider: Web3Provider
    let transaction: Transaction
    let chain: EthereumChain
    let address: String
    let peerMeta: PeerMeta
    let completion: (Transaction?) -> Void
}
