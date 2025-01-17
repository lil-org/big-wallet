// ∅ 2025 lil org

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

    static func showTextInputAlert(title: String, message: String?, initialText: String?, placeholder: String, completion: @escaping ((String?) -> Void)) {
        let alert = Alert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        alert.alertStyle = .informational
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        textField.placeholderString = placeholder
        textField.stringValue = initialText ?? ""
        alert.accessoryView = textField
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            completion(textField.stringValue)
        } else {
            completion(nil)
        }
    }
}
