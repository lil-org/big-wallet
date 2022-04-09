// Copyright © 2022 Tokenary. All rights reserved.
// Helper methods for `UIResponder`

import UIKit

extension UIResponder {
    func firstResponder<T>(of type: T.Type) -> T? {
        if let responder = self as? T {
            return responder
        } else {
            guard let next = self.next else { return nil }
            return next.firstResponder(of: type)
        }
    }
    
    var parentViewController: UIViewController? {
        return next as? UIViewController ?? next?.parentViewController
    }
}
