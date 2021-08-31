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

class PasswordAlert: Alert {
    
    let passwordTextField: NSSecureTextField = {
        let passwordTextField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 20))
        passwordTextField.bezelStyle = .roundedBezel
        passwordTextField.isAutomaticTextCompletionEnabled = false
        passwordTextField.alignment = .center
        return passwordTextField
    }()
    
    init(title: String) {
        super.init()
        
        messageText = title
        alertStyle = .informational
        addButton(withTitle: "OK")
        addButton(withTitle: "Cancel")
        accessoryView = passwordTextField
    }
}

class LoadingAlert: Alert {
    
    init(title: String) {
        super.init()
        
        addButton(withTitle: Strings.cancel)
        messageText = title
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 230, height: 20))
        progress.style = .spinning
        progress.startAnimation(nil)
        accessoryView = progress
    }
}
