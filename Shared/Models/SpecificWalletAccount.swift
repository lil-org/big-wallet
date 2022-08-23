// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct SpecificWalletAccount: Hashable {
    let walletId: String
    let account: Account
}
