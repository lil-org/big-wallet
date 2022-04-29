// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public typealias OktTransactionClosure = (_ id: Int64, _ event: WCEvent, _ transaction: WCOKExChainTransaction) -> Void

public struct WCOKExChainInteractor {
    public var onTransaction: OktTransactionClosure?

    func handleEvent(_ event: WCEvent, topic: String, decrypted: Data) throws {
        switch event {
        case .oktSignTransaction, .oktSendTransaction:
            let request: JSONRPCRequest<[WCOKExChainTransaction]> = try event.decode(decrypted)
            guard !request.params.isEmpty else { throw WCError.badJSONRPCRequest }
            onTransaction?(request.id, event, request.params[0])
        default:
            break
        }
    }
}
