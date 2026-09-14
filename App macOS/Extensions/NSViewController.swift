// ∅ 2026 lil org

import Cocoa
import SwiftUI

@MainActor
protocol NativeApprovalReviewTeardown: AnyObject {
    func invalidateNativeApprovalReview()
}

extension NSViewController {

    var nativeApprovalPeer: PeerMeta? {
        (view.window?.windowController as? WalletWindowController)?
            .approvalPeer
    }
    
    func makeHostingWindow<Content>(content: Content, title: String? = nil) -> NSWindow where Content: View {
        let hostingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.closable, .fullSizeContentView, .titled],
            backing: .buffered, defer: false)
        if let title = title {
            hostingWindow.title = title
        }
        hostingWindow.center()
        hostingWindow.titleVisibility = .visible
        hostingWindow.titlebarAppearsTransparent = false
        hostingWindow.isMovableByWindowBackground = true
        hostingWindow.backgroundColor = NSColor.windowBackgroundColor
        hostingWindow.isOpaque = false
        hostingWindow.hasShadow = true

        hostingWindow.contentView?.wantsLayer = true
        hostingWindow.contentView?.layer?.cornerRadius = 10
        hostingWindow.contentView?.layer?.masksToBounds = true

        hostingWindow.isReleasedWhenClosed = false
        hostingWindow.contentView = NSHostingView(rootView: content)
        return hostingWindow
    }
    
    func presentAlert(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard nativeApprovalPeer != nil,
              let window = view.window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    func presentMessageAlert(
        _ message: String,
        style: NSAlert.Style,
        completion: @escaping () -> Void = {}
    ) {
        let alert = Alert()
        alert.messageText = message
        alert.alertStyle = style
        alert.addButton(withTitle: Strings.ok)
        presentAlert(alert) { _ in completion() }
    }

    func presentTextInputAlert(
        title: String,
        initialText: String?,
        placeholder: String,
        completion: @escaping (String?) -> Void
    ) {
        let alert = Alert()
        alert.messageText = title
        alert.alertStyle = .informational
        let textField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 230, height: 24)
        )
        textField.placeholderString = placeholder
        textField.stringValue = initialText ?? ""
        alert.accessoryView = textField
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { response in
            completion(
                response == .alertFirstButtonReturn
                    ? textField.stringValue
                    : nil
            )
        }
    }

    func endAllSheets() {
        if let sheets = view.window?.sheets, !sheets.isEmpty {
            for sheet in sheets {
                view.window?.endSheet(sheet)
            }
        }
    }
    
}
