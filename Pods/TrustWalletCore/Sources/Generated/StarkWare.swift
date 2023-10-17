// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct StarkWare {

    /// Generates the private stark key at the given derivation path from a valid eth signature
    ///
    /// - Parameter derivationPath: non-null StarkEx Derivation path
    /// - Parameter signature: valid eth signature
    /// - Returns:  The private key for the specified derivation path/signature
    public static func getStarkKeyFromSignature(derivationPath: DerivationPath, signature: String) -> PrivateKey {
        let signatureString = TWStringCreateWithNSString(signature)
        defer {
            TWStringDelete(signatureString)
        }
        return PrivateKey(rawValue: TWStarkWareGetStarkKeyFromSignature(derivationPath.rawValue, signatureString))
    }


    init() {
    }


}
