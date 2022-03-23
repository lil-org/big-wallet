// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UIView {
    static var fromNib: Self {
        Bundle.main.loadNibNamed(String(describing: Self.self), owner: nil, options: nil)![0] as! Self
    }
    
    func addSubviewConstrainedToFrame(_ subview: UIView) {
        self.addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        let firstConstraints = NSLayoutConstraint.constraints(
            withVisualFormat: "H:|-0-[subview]-0-|",
            options: .directionLeadingToTrailing, metrics: nil,
            views: ["subview": subview]
        )
        let secondConstraints = NSLayoutConstraint.constraints(
            withVisualFormat: "V:|-0-[subview]-0-|",
            options: .directionLeadingToTrailing, metrics: nil,
            views: ["subview": subview]
        )
        self.addConstraints(firstConstraints + secondConstraints)
    }
}
