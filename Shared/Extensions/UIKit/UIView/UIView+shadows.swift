// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIView {
    public func applySimpleShadow(with shadowAppearance: CALayer.ShadowAppearance) {
        self.layer.applySimpleShadow(with: shadowAppearance)
    }
    
    public func applyShadow(
        for shadowPath: UIBezierPath,
        having shadowAppearance: CALayer.ShadowAppearance,
        isRasterizedAtScale: Bool = true
    ) {
        self.layer.applyShadow(for: UIBezierPath(rect: self.bounds), having: shadowAppearance)
        self.layer.shouldRasterize = true
        self.layer.rasterizationScale = isRasterizedAtScale ? UIScreen.main.scale : 1
    }
}
