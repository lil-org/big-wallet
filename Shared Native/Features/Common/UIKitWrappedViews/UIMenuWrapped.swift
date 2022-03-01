// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import UIKit

struct UIMenuWrapped<Content: View, Preview: View>: View {
    
    var content: Content
    var preview: Preview
    var menu: UIMenu
    
    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder preview: @escaping () -> Preview,
        actions: @escaping () -> UIMenu
    ) {
        self.content = content()
        self.preview = preview()
        self.menu = actions()
    }
    
    var body: some View {
        ZStack {
            content
                .hidden()
                .overlay(UIMenuWrappedHelper(content: self.content, preview: self.preview, actions: self.menu))
            
        }
    }
}

struct UIMenuWrappedHelper<Content: View, Preview: View>: UIViewRepresentable {
    var content: Content
    var preview: Preview
    var actions: UIMenu
    
    init(content: Content, preview: Preview, actions: UIMenu) {
        self.content = content
        self.preview = preview
        self.actions = actions
    }
    
    func makeUIView(context: Context) -> some UIView {
        let view = UIView()
        view.backgroundColor = .red
        
        let hostView = UIHostingController(rootView: content)
        
        let constraints = [
            hostView.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostView.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostView.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostView.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostView.view.widthAnchor.constraint(equalTo: view.widthAnchor),
            hostView.view.heightAnchor.constraint(equalTo: view.heightAnchor)
        ]
        
        view.addSubview(hostView.view)
        view.addConstraints(constraints)
        hostView.view.translatesAutoresizingMaskIntoConstraints = false
        
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        
        return view
    }
    
    func updateUIView(_ uiView: UIViewType, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: UIMenuWrappedHelper
        init(parent: UIMenuWrappedHelper) {
            self.parent = parent
        }
            
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            return UIContextMenuConfiguration(identifier: nil) {
                let previewController = PreviewHostingController(rootView: self.parent.preview)
                return previewController
            } actionProvider: { _ in
                self.parent.actions
            }
        }
        
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionCommitAnimating
        ) {
            animator.addCompletion {}
        }
    }
}

private final class PreviewHostingController<Content: View>: UIHostingController<Content> {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        preferredContentSize.height = view.intrinsicContentSize.height
        preferredContentSize.width = view.intrinsicContentSize.width
    }
}
