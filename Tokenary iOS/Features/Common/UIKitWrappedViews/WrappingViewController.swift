// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import SwiftUI

class WrappingViewController<ContentView>: UIViewController where ContentView: View {
    public let swiftUIHostingController: UIHostingController<ContentView>
    public var swiftUIView: ContentView {
        self.swiftUIHostingController.rootView
    }
    
    init(rootView: ContentView) {
        self.swiftUIHostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.addChild(self.swiftUIHostingController)
        self.swiftUIHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.swiftUIHostingController.view)
        self.swiftUIHostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            self.swiftUIHostingController.view.widthAnchor.constraint(equalTo: self.view.widthAnchor),
            self.swiftUIHostingController.view.heightAnchor.constraint(equalTo: self.view.heightAnchor),
            self.swiftUIHostingController.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.swiftUIHostingController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.swiftUIHostingController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.swiftUIHostingController.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
    }
}
