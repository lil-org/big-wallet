// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct NetworksListView: View {
    @State private var searchText: String = ""
    let items: [String] = Networks.all().map { $0.name }
    
    @Environment(\.presentationMode) var presentationMode

    var filteredItems: [String] {
        items.filter { $0.contains(searchText) || searchText.isEmpty }
    }

    var body: some View {
        VStack {
            SearchBar(text: $searchText)
            List(filteredItems, id: \.self) { item in
                Text(item)
            }
            
            Divider() // Separate the list from the buttons

            HStack {
                Spacer()
                Button("Cancel") {
                    self.presentationMode.wrappedValue.dismiss()
                }
                .padding()

                Button("OK") {
                    self.presentationMode.wrappedValue.dismiss()
                }
                .padding()
            }
        }
    }
}

struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack {
            TextField("Search ...", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }.padding()
    }
}

#if os(iOS)
import UIKit

extension UIViewController {
    func showPopup() {
        let contentView = NetworksListView()
        let hostingController = UIHostingController(rootView: contentView)
        hostingController.modalPresentationStyle = .fullScreen
        self.present(hostingController, animated: true, completion: nil)
    }
}

#elseif os(macOS)
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
