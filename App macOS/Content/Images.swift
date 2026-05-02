// ∅ 2026 lil org

import Cocoa

struct Images {
    
    static var multicoinWalletPreferences: NSImage { systemName("ellipsis.rectangle") }
    static var preferences: NSImage { systemName("gearshape") }
    static var network: NSImage { systemName("network") }
    static var circleFill: NSImage { systemName("circle.fill") }
    static var solana: NSImage { named("solana") }
    
    private static func named(_ name: String) -> NSImage {
        return NSImage(named: name)!
    }
    
    private static func systemName(_ systemName: String) -> NSImage {
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)!
    }
    
}
