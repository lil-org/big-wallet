import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Foundation

struct Identifiers {
    
    static let safariExtensionBundle = "org.lil.wallet.Safari"
    static let macOSAppBundle = "org.lil.wallet"
    static let macOSAmbientBundle = "org.lil.wallet.ambient"
    
}

enum CurrentApp {

    static var isDockApp: Bool {
        return Bundle.main.bundleIdentifier == Identifiers.macOSAppBundle
    }

    static var canCreatePassword: Bool {
        return isDockApp
    }

}
