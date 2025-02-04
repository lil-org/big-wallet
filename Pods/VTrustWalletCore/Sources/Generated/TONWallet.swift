// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// TON wallet operations.
public final class TONWallet {

    /// Constructs a TON Wallet V4R2 stateInit encoded as BoC (BagOfCells) for the given `public_key`.
    ///
    /// - Parameter publicKey: wallet's public key.
    /// - Parameter workchain: TON workchain to which the wallet belongs. Usually, base chain is used (0).
    /// - Parameter walletId: wallet's ID allows to create multiple wallets for the same private key.
    /// - Returns: Pointer to a base64 encoded Bag Of Cells (BoC) StateInit. Null if invalid public key provided.
    public static func buildV4R2StateInit(publicKey: PublicKey, workchain: Int32, walletId: Int32) -> String? {
        guard let result = TWTONWalletBuildV4R2StateInit(publicKey.rawValue, workchain, walletId) else {
            return nil
        }
        return TWStringNSString(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}
