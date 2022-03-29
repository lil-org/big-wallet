// Copyright © 2022 Tokenary. All rights reserved.
// Helper properties & methods over UITextInput

import UIKit

extension UITextInput {
    var selectedRange: NSRange? {
        guard let selectedRange = selectedTextRange else { return nil }
        return NSRange(
            location: offset(from: beginningOfDocument, to: selectedRange.start),
            length: offset(from: selectedRange.start, to: selectedRange.end)
        )
    }
}
