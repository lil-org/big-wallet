// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIApplication {
    public static var activeWindow: UIWindow {
        guard
            let activeKeyWindow = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
        else {
            fatalError("No active window found!")
        }
        return activeKeyWindow
    }
}
