// ∅ 2024 lil org

import Foundation

extension Notification.Name {
    static let connectionAppeared = Notification.Name("connectionAppeared")
    static let walletsChanged = Notification.Name("walletsChanged")
    static let receievedWalletRequest = Notification.Name("receievedWalletRequest")
    static let mustTerminate = Notification.Name("terminateOtherInstances")
}
