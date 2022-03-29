// Copyright © 2022 Tokenary. All rights reserved.

import AppKit
import SwiftUI

class WrappingViewController<ContentView>: NSViewController where ContentView: View {
    let swiftUIHostingController: NSHostingController<ContentView>
    var swiftUIView: ContentView {
        swiftUIHostingController.rootView
    }
    
    init(rootView: ContentView) {
        self.swiftUIHostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func loadView() {
        view = NSView(frame: .init(x: .zero, y: .zero, width: 250, height: 350))
        
        addChild(swiftUIHostingController)
        swiftUIHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(swiftUIHostingController.view)

        NSLayoutConstraint.activate([
            swiftUIHostingController.view.widthAnchor.constraint(equalTo: view.widthAnchor),
            swiftUIHostingController.view.heightAnchor.constraint(equalTo: view.heightAnchor),
            swiftUIHostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            swiftUIHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            swiftUIHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            swiftUIHostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
