// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct NetworksListView: View {
    
    let mainnets = Networks.allMainnets
    let testnets = Networks.allTestnets
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section() {
                        ForEach(mainnets, id: \.self) { item in
                            Text(item.name)
                        }
                    }
                    
                    Section(header: Text(Strings.testnets)) {
                        ForEach(testnets, id: \.self) { item in
                            Text(item.name)
                        }
                    }
                }
            }
            .navigationBarTitle(Strings.selectNetwork, displayMode: .large)
            .navigationBarItems(leading: Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Text(Strings.cancel)
            })
        }
    }
}

#if os(macOS)

import Cocoa

var popupWindow: NSWindow? // keep a reference within a NSViewController

extension NSViewController {
    
    func showPopup() {
        let contentView = NetworksListView()
        
        popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.closable, .fullSizeContentView, .titled],
            backing: .buffered, defer: false)
        popupWindow?.center()
        popupWindow?.titleVisibility = .hidden
        popupWindow?.titlebarAppearsTransparent = true
        popupWindow?.isMovableByWindowBackground = true
        popupWindow?.backgroundColor = NSColor.windowBackgroundColor
        popupWindow?.isOpaque = false
        popupWindow?.hasShadow = true
        
        popupWindow?.contentView?.wantsLayer = true
        popupWindow?.contentView?.layer?.cornerRadius = 10
        popupWindow?.contentView?.layer?.masksToBounds = true
        
        popupWindow?.isReleasedWhenClosed = false
        popupWindow?.contentView = NSHostingView(rootView: contentView)
        popupWindow?.makeKeyAndOrderFront(nil)
    }
    
}

#endif
