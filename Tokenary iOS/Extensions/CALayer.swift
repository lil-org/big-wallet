// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension CALayer {
    struct ShadowAppearance {
        let color: UIColor
        let opacity: Float
        let offset: CGPoint
        let radius: CGFloat
        let spread: Float?
        
        init(
            color: UIColor, opacity: Float, offset: CGPoint, radius: CGFloat, spread: Float? = nil
        ) {
            self.color = color
            self.opacity = opacity
            self.offset = offset
            self.radius = radius
            self.spread = spread
        }
        
        static let none = ShadowAppearance(
            color: .clear, opacity: .zero, offset: .zero, radius: .zero
        )
    }
    
    func applySimpleShadow(with shadowAppearance: ShadowAppearance) {
        self.shadowColor = shadowAppearance.color.cgColor
        self.shadowOpacity = shadowAppearance.opacity
        self.shadowOffset = CGSize(width: shadowAppearance.offset.x, height: shadowAppearance.offset.y)
        self.shadowRadius = shadowAppearance.radius
    }
    
    func applyShadow(for shadowPath: UIBezierPath, having shadowAppearance: ShadowAppearance) {
        self.applySimpleShadow(with: shadowAppearance)
        self.masksToBounds = true
        guard let shadowPathSpread = shadowAppearance.spread else {
            self.shadowPath = shadowPath.cgPath
            return
        }
        let dx = CGFloat(-shadowPathSpread)
        let newRect = self.bounds.insetBy(dx: dx, dy: dx) // both sides
        let translation = CGAffineTransform(from: shadowPath.bounds, to: newRect)
        shadowPath.apply(translation)
        self.shadowPath = shadowPath.cgPath
    }
}
