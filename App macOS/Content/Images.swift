// ∅ 2026 lil org

import Cocoa

struct Images {
    
    static var multicoinWalletPreferences: NSImage { systemName("ellipsis.rectangle") }
    static var preferences: NSImage { systemName("gearshape") }

    private static func systemName(_ systemName: String) -> NSImage {
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)!
    }
    
}
