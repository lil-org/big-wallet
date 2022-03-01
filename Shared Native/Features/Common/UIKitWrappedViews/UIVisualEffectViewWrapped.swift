// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import SwiftUI

public struct UIVisualEffectViewWrapped: UIViewRepresentable {
    public let style: UIBlurEffect.Style
    public let cornerRadius: CGFloat?
    
    public init(_ style: UIBlurEffect.Style, cornerRadius: CGFloat? = nil) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: self.style))
    }
    
    public func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        if let cornerRadius = self.cornerRadius {
            uiView.clipsToBounds = true
            uiView.layer.cornerRadius = cornerRadius
        }
    }
}
