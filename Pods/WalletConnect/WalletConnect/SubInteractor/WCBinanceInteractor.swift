// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import PromiseKit

public typealias BnbSignClosure = (_ id: Int64, _ order: WCBinanceOrder) -> Void

public struct WCBinanceInteractor {
    public var onSign: BnbSignClosure?

    var confirmResolvers: [Int64: Resolver<WCBinanceTxConfirmParam>] = [:]

    mutating func handleEvent(_ event: WCEvent, topic: String, decrypted: Data) throws {
        switch event {
        case .bnbSign:
            if let request: JSONRPCRequest<[WCBinanceTradeOrder]> = try? event.decode(decrypted) {
                onSign?(request.id, request.params[0])
            } else if let request: JSONRPCRequest<[WCBinanceCancelOrder]> = try? event.decode(decrypted) {
                onSign?(request.id, request.params[0])
            } else if let request: JSONRPCRequest<[WCBinanceTransferOrder]> = try? event.decode(decrypted) {
                onSign?(request.id, request.params[0])
            }
        case .bnbTransactionConfirm:
            let request: JSONRPCRequest<[WCBinanceTxConfirmParam]> = try event.decode(decrypted)
            guard !request.params.isEmpty else { throw WCError.badJSONRPCRequest }
            self.confirmResolvers[request.id]?.fulfill(request.params[0])
            self.confirmResolvers[request.id] = nil
        default:
            break
        }
    }
}
