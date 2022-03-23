// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import SwiftUI

struct UIVisualEffectViewWrapped: UIViewRepresentable {
    let style: UIBlurEffect.Style
    let cornerRadius: CGFloat?
    
    init(_ style: UIBlurEffect.Style, cornerRadius: CGFloat? = nil) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: self.style))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        if let cornerRadius = self.cornerRadius {
            uiView.clipsToBounds = true
            uiView.layer.cornerRadius = cornerRadius
        }
    }
}
