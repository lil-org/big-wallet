// Copyright © 2021 Tokenary. All rights reserved.

import CoreGraphics
#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

extension CGFloat {
#if canImport(UIKit)
    static let pixel: CGFloat = 1 / UIScreen.main.scale
#elseif canImport(AppKit)
    static let pixel: CGFloat = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
#endif
}
