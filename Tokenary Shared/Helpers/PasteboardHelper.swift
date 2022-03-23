// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif

struct PasteboardHelper {
    static func setPlainNotNil(_ string: String?) {
        if let string = string {
            PasteboardHelper.setPlain(string)
        }
    }
    
    static func setPlain(_ string: String) {
#if canImport(UIKit)
        UIPasteboard.general.setValue(
            string as Any, forPasteboardType: UTType.utf8PlainText.identifier
        )
#elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(string, forType: .string)
#endif
    }
}
