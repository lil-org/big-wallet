// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

extension NSViewController {
    
    func showHostingWindow<Content>(content: Content, title: String) -> Int where Content: View {
        let hostingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.closable, .fullSizeContentView, .titled],
            backing: .buffered, defer: false)
        hostingWindow.title = title
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
        hostingWindow.makeKeyAndOrderFront(nil)

        return hostingWindow.windowNumber
    }
    
}
