// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIEdgeInsets {
    
    // MARK: - Constructors
    
    public init(top: CGFloat = .zero, bottom: CGFloat = .zero, left: CGFloat = .zero, right: CGFloat = .zero) {
        self.init(top: top, left: left, bottom: bottom, right: right)
    }
    
    public init(vertical: CGFloat, left: CGFloat = .zero, right: CGFloat = .zero) {
        self.init(top: vertical, left: left, bottom: vertical, right: right)
    }
    
    public init(top: CGFloat = .zero, bottom: CGFloat = .zero, horizontal: CGFloat) {
        self.init(top: top, left: horizontal, bottom: bottom, right: horizontal)
    }

    public init(vertical: CGFloat = .zero, horizontal: CGFloat = .zero) {
        self.init(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    public init(all inset: CGFloat = .zero) {
        self.init(top: inset, left: inset, bottom: inset, right: inset)
    }
}
