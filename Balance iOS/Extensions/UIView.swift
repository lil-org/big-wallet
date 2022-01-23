// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

func loadNib<View: UIView>(_ type: View.Type) -> View {
    return Bundle.main.loadNibNamed(String(describing: type), owner: nil, options: nil)![0] as! View
}

extension UIView {
    
    func addSubviewConstrainedToFrame(_ subview: UIView) {
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        let firstConstraints = NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[subview]-0-|", options: .directionLeadingToTrailing, metrics: nil, views: ["subview": subview])
        let secondConstraints = NSLayoutConstraint.constraints(withVisualFormat: "V:|-0-[subview]-0-|", options: .directionLeadingToTrailing, metrics: nil, views: ["subview": subview])
        addConstraints(firstConstraints + secondConstraints)
    }
    
}
