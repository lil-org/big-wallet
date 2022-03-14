// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif

public struct LinkHelper {
    public static func open(_ url: URL?) {
        if let url = url {
#if canImport(UIKit)
            UIApplication.shared.open(url)
#elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
#endif
        }
    }
}
