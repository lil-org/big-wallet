// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIControl {
    func addAction(for event: UIControl.Event, handler: @escaping UIActionHandler) {
        addAction(UIAction(identifier: UIAction.Identifier(String(event.rawValue)), handler: handler), for: event)
    }
}
