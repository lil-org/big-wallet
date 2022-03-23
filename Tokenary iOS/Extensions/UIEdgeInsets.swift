// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIEdgeInsets {
    
    // MARK: - Constructors
    
    init(top: CGFloat = .zero, bottom: CGFloat = .zero, left: CGFloat = .zero, right: CGFloat = .zero) {
        self.init(top: top, left: left, bottom: bottom, right: right)
    }
    
    init(vertical: CGFloat, left: CGFloat = .zero, right: CGFloat = .zero) {
        self.init(top: vertical, left: left, bottom: vertical, right: right)
    }
    
    init(top: CGFloat = .zero, bottom: CGFloat = .zero, horizontal: CGFloat) {
        self.init(top: top, left: horizontal, bottom: bottom, right: horizontal)
    }

    init(vertical: CGFloat = .zero, horizontal: CGFloat = .zero) {
        self.init(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    init(all inset: CGFloat = .zero) {
        self.init(top: inset, left: inset, bottom: inset, right: inset)
    }
}
