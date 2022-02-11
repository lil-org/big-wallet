// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct DappRequestProcessor {
    
    private static let ethereum = Ethereum.shared
    
    static func processSafariRequest(_ safariRequest: SafariRequest) -> DappRequestAction {
        return .none
    }
    
}

enum DappRequestAction {
    case none
    case selectAccount(SelectAccountAction)
    case sign(SignAction)
}

struct SelectAccountAction {
    let provider: Web3Provider
    let completion: (EthereumChain?, TokenaryWallet?) -> Void
}

struct SignAction {
    let provider: Web3Provider
    let subject: ApprovalSubject
    let meta: String
    let peerMeta: PeerMeta
    let completion: (Bool) -> Void
}
