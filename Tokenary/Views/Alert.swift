// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class Alert: NSAlert {
    
    override func runModal() -> NSApplication.ModalResponse {
        defer {
            Agent.shared.statusBarButtonIsBlocked = false
        }
        Agent.shared.statusBarButtonIsBlocked = true
        return super.runModal()
    }
    
    static func showWithMessage(_ message: String, style: NSAlert.Style) {
        let alert = Alert()
        alert.messageText = message
        alert.alertStyle = style
        alert.addButton(withTitle: Strings.ok)
        _ = alert.runModal()
    }
    
    static func showSafariPrompt() {
        let alert = Alert()
        alert.messageText = "Tokenary now works great in Safari."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable Safari extension")
        alert.addButton(withTitle: Strings.ok)
        if alert.runModal() == .alertFirstButtonReturn {
            Agent.shared.enableSafariExtension()
        }
    }
    
}
