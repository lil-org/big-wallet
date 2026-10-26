import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

extension NSPasteboard {
    
    func clearAndSetString(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
    
}
