// Copyright © 2022 Tokenary. All rights reserved.
// Helper properties & methods over UITextInput

import UIKit

extension UITextInput {
    var selectedRange: NSRange? {
        guard let selectedRange = self.selectedTextRange else { return nil }
        return NSRange(
            location: self.offset(from: self.beginningOfDocument, to: selectedRange.start),
            length: self.offset(from: selectedRange.start, to: selectedRange.end)
        )
    }
}
