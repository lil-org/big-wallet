// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import UIKit

extension Color {
    public init(
        light lightModeColor: @escaping @autoclosure () -> Color,
        dark darkModeColor: @escaping @autoclosure () -> Color
    ) {
        self.init(
            UIColor(
                light: UIColor(lightModeColor()),
                dark: UIColor(darkModeColor())
            )
        )
    }
}
