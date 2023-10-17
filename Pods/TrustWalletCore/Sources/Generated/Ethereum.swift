// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public struct Ethereum {

    /// Generate a layer 2 eip2645 derivation path from eth address, layer, application and given index.
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter ethAddress: non-null Ethereum address
    /// - Parameter layer:  non-null layer 2 name (E.G starkex)
    /// - Parameter application: non-null layer 2 application (E.G immutablex)
    /// - Parameter index: non-null layer 2 index (E.G 1)
    /// - Returns: a valid eip2645 layer 2 derivation path as a string
    public static func eip2645GetPath(ethAddress: String, layer: String, application: String, index: String) -> String {
        let ethAddressString = TWStringCreateWithNSString(ethAddress)
        defer {
            TWStringDelete(ethAddressString)
        }
        let layerString = TWStringCreateWithNSString(layer)
        defer {
            TWStringDelete(layerString)
        }
        let applicationString = TWStringCreateWithNSString(application)
        defer {
            TWStringDelete(applicationString)
        }
        let indexString = TWStringCreateWithNSString(index)
        defer {
            TWStringDelete(indexString)
        }
        return TWStringNSString(TWEthereumEip2645GetPath(ethAddressString, layerString, applicationString, indexString))
    }


    init() {
    }


}
