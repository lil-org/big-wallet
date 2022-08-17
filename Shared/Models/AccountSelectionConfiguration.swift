// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct AccountSelectionConfiguration {
    let peer: PeerMeta?
    let coinType: CoinType?
    var selectedAccounts: Set<SpecificWalletAccount>
    let completion: ((EthereumChain?, SpecificWalletAccount?) -> Void)
}
