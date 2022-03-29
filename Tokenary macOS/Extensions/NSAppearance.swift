// Copyright © 2022 Tokenary. All rights reserved.

import AppKit

extension NSAppearance {
    var isDarkMode: Bool {
        if bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        } else {
            return false
        }
    }
}
