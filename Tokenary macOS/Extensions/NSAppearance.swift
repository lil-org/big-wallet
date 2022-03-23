// Copyright © 2022 Tokenary. All rights reserved.

import AppKit

extension NSAppearance {
    var isDarkMode: Bool {
        if self.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        } else {
            return false
        }
    }
}
