import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Foundation

extension Notification.Name {
    static let walletsChanged = Notification.Name("walletsChanged")
    static let walletsLoadStateChanged = Notification.Name("walletsLoadStateChanged")
    static let walletStoreChanged = Notification.Name("walletStoreChanged")
}
