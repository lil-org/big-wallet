// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct NetworksListView: View {
    
    private let mainnets = Networks.allMainnets
    private let testnets = Networks.allTestnets
    
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedChainId: Int?
    
    private let completion: ((Int?) -> Void)
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    networkSection(networks: mainnets)
                    networkSection(networks: testnets, title: Strings.testnets)
                }
            }
            .navigationBarTitle(Strings.selectNetwork, displayMode: .large)
            .navigationBarItems(leading: Button(action: {
                completion(selectedChainId)
                presentationMode.wrappedValue.dismiss() }) {
                Text(Strings.done).bold()
            })
        }
    }
    
    init(selectedChainId: Int?, completion: @escaping ((Int?) -> Void)) {
        self._selectedChainId = State(initialValue: selectedChainId)
        self.completion = completion
    }
    
    @ViewBuilder
    private func networkSection(networks: [EthereumNetwork], title: String? = nil) -> some View {
        Section(header: title.map { Text($0) }) {
            ForEach(networks, id: \.self) { network in
                HStack {
                    Text(network.name)
                    Spacer()
                    if selectedChainId == network.chainId {
                        Image.checkmark.foregroundStyle(.selection)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedChainId == network.chainId {
                        selectedChainId = nil
                    } else {
                        selectedChainId = network.chainId
                    }
                }
            }
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
