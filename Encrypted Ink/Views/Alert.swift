// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class Alert: NSAlert {
    
    override func runModal() -> NSApplication.ModalResponse {
        defer {
            Agent.shared.statusBarButtonIsBlocked = false
        }
        Agent.shared.statusBarButtonIsBlocked = true
        return super.runModal()
    }
    
    static func showWalletConnectInstructions() {
        Alert.showWithMessage("1 — Open dapp website\n\n2 — Click “Copy to clipboard”\nunder WalletConnect QR code\n\n3 — Open Encrypted Ink", style: .informational)
    }
    
    static func showWithMessage(_ message: String, style: NSAlert.Style) {
        let alert = Alert()
        alert.messageText = message
        alert.alertStyle = style
        alert.addButton(withTitle: Strings.ok)
        _ = alert.runModal()
    }
    
}
