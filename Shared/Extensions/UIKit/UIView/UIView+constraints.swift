// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit

extension UIView {
    public func fill(_ view: UIView, toMargins: Bool = false, insets: NSDirectionalEdgeInsets = .zero) {
        view.addSubview(self)
        self.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate {
            if toMargins {
                self.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor, constant: insets.top)
                self.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: insets.leading)
                self.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -insets.trailing)
                self.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor, constant: -insets.bottom)
            } else {
                self.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top)
                self.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.leading)
                self.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.trailing)
                self.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -insets.bottom)
            }
        }
    }

    public func center(in view: UIView, size: CGSize? = nil) {
        view.addSubview(self)
        self.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate {
            self.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            self.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        }
        
        guard let size = size else { return }
        
        NSLayoutConstraint.activate {
            view.widthAnchor.constraint(equalToConstant: size.width)
            view.heightAnchor.constraint(equalToConstant: size.height)
        }
    }
}
