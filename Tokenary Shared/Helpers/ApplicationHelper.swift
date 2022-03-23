// Copyright © 2022 Tokenary. All rights reserved.

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif

struct ApplicationHelper {
    static func resignFirstResponder() {
#if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
#elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
#endif
    }
}
