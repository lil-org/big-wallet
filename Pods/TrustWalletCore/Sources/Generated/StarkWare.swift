// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct StarkWare {

    /// Generates the private stark key at the given derivation path from a valid eth signature
    ///
    /// - Parameter derivationPath: non-null StarkEx Derivation path
    /// - Parameter signature: valid eth signature
    /// - Returns:  The private key for the specified derivation path/signature, or `nullptr` if the signature or derivation path is invalid or an internal error occurs.
    public static func getStarkKeyFromSignature(derivationPath: DerivationPath, signature: String) -> PrivateKey? {
        let signatureString = TWStringCreateWithNSString(signature)
        defer {
            TWStringDelete(signatureString)
        }
        guard let value = TWStarkWareGetStarkKeyFromSignature(derivationPath.rawValue, signatureString) else {
            return nil
        }
        return PrivateKey(rawValue: value)
    }


    init() {
    }


}
