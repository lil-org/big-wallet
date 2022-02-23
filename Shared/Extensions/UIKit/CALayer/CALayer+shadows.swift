// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension CALayer {
    public struct ShadowAppearance {
        public let color: UIColor
        public let opacity: Float
        public let offset: CGPoint
        public let radius: CGFloat
        public let spread: Float?
        
        public init(
            color: UIColor, opacity: Float, offset: CGPoint, radius: CGFloat, spread: Float? = nil
        ) {
            self.color = color
            self.opacity = opacity
            self.offset = offset
            self.radius = radius
            self.spread = spread
        }
        
        public static let none = ShadowAppearance(
            color: .clear, opacity: .zero, offset: .zero, radius: .zero
        )
    }
    
    public func applySimpleShadowInterfaceStyleAccounting(with shadowAppearance: ShadowAppearance) {
        if UITraitCollection.current.userInterfaceStyle == .dark {
            self.dropShadow()
        } else {
            self.applySimpleShadow(with: shadowAppearance)
        }
    }
    
    public func applySimpleShadow(with shadowAppearance: ShadowAppearance) {
        self.shadowColor = shadowAppearance.color.cgColor
        self.shadowOpacity = shadowAppearance.opacity
        self.shadowOffset = CGSize(width: shadowAppearance.offset.x, height: shadowAppearance.offset.y)
        self.shadowRadius = shadowAppearance.radius
    }
    
    public func applyShadow(for shadowPath: UIBezierPath, having shadowAppearance: ShadowAppearance) {
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
    
    public func dropShadow() {
        self.shadowPath = nil
        self.shadowOpacity = .zero
        self.shadowOffset = CGSize(width: .zero, height: -3) // default
        self.shadowRadius = 3 // default
    }
}
