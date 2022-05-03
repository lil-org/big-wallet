// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation

public typealias TransactionSignClosure = (_ id: Int64, _ transaction: WCTrustTransaction) -> Void
public typealias GetAccountsClosure = (_ id: Int64) -> Void

public struct WCTrustInteractor {
    public var onTransactionSign: TransactionSignClosure?
    public var onGetAccounts: GetAccountsClosure?

    func handleEvent(_ event: WCEvent, topic: String, decrypted: Data) throws {
        switch event {
        case .trustSignTransacation:
            let request: JSONRPCRequest<[WCTrustTransaction]> = try event.decode(decrypted)
            guard !request.params.isEmpty else { throw WCError.badJSONRPCRequest }
            onTransactionSign?(request.id, request.params[0])
        case .getAccounts:
            let request: JSONRPCRequest<[String]> = try event.decode(decrypted)
            onGetAccounts?(request.id)
        default:
            break
        }
    }
}
