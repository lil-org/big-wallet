// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

struct Window {
    
    static func closeAll() {
        NSApplication.shared.windows.forEach { $0.close() }
    }
    
    static func activateSafari() {
        if let browser = NSWorkspace().runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            browser.activate(options: .activateIgnoringOtherApps)
        }
    }
    
}
