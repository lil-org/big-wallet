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
        
//        alert.suppressionButton.title = "Do not show this warning again"
//        let defaults = UserDefaults.standard
//
//        if defaults.bool(forKey: alertSuppressionKey) {
//            print("Alert suppressed")
//        } else {
//            if let suppressionButton = alert.suppressionButton, suppressionButton.state == .on {
//                defaults.set(true, forKey: "AlertSuppression")
//            }
//        }
    }
    
    static func showPasswordAlert(title: String, completion: @escaping (String?) -> Void) {
        let alert = Alert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        
        let passwordTextField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 20))
        passwordTextField.bezelStyle = .roundedBezel
        alert.accessoryView = passwordTextField
        passwordTextField.isAutomaticTextCompletionEnabled = false
        passwordTextField.alignment = .center
        
        DispatchQueue.main.async {
            passwordTextField.becomeFirstResponder()
        }
        
        if alert.runModal() == .alertFirstButtonReturn {
            completion(passwordTextField.stringValue)
        } else {
            completion(nil)
        }
    }
}
