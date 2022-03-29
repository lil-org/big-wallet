// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import SwiftUI

class WrappingViewController<ContentView>: UIViewController where ContentView: View {
    let swiftUIHostingController: UIHostingController<ContentView>
    var swiftUIView: ContentView {
        swiftUIHostingController.rootView
    }
    
    init(rootView: ContentView) {
        self.swiftUIHostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        addChild(swiftUIHostingController)
        swiftUIHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(swiftUIHostingController.view)
        swiftUIHostingController.didMove(toParent: self)

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
