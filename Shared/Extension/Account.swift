// Copyright © 2022 Tokenary. All rights reserved.

import WalletCore
import BlockiesSwift

extension Account {

    var croppedAddress: String {
        let without0x = coin == .ethereum ? String(address.dropFirst(2)) : address
        return without0x.prefix(4) + "..." + without0x.suffix(4)
    }
    
    var image: Image? {
        if coin == .ethereum {
            return Blockies(seed: address.lowercased()).createImage()
        } else {
            return Images.logo(coin: coin)
        }
    }
    
}
