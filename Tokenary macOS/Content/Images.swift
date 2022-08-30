// Copyright © 2022 Tokenary. All rights reserved.

import Cocoa
import WalletCore

struct Images {
    
    static var statusBarIcon: NSImage { named("Status") }
    static var multicoinWalletPreferences: NSImage { systemName("ellipsis.rectangle") }
    static var network: NSImage { systemName("network") }
 
    static func logo(coin: CoinType) -> NSImage {
        return named("Logo" + coin.name)
    }
    
    private static func named(_ name: String) -> NSImage {
        return NSImage(named: name)!
    }
    
    private static func systemName(_ systemName: String) -> NSImage {
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)!
    }
    
}
