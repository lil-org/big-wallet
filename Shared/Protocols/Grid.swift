// Copyright © 2022 Tokenary. All rights reserved.
// Special-purpose protocol that holds layout-related constants(like distance between views)

import UIKit
import SwiftUI

public protocol Grid {}

extension Grid {
    public var zero: CGFloat { .zero }
    public var pixel: CGFloat { 1 / UIScreen.main.nativeScale }
    public var space05: CGFloat { 0.5 }
    public var space1: CGFloat { 1 }
    public var space2: CGFloat { 2 }
    public var space4: CGFloat { 4 }
    public var space6: CGFloat { 6 }
    public var space8: CGFloat { 8 }
    public var space10: CGFloat { 10 }
    public var space12: CGFloat { 12 }
    public var space14: CGFloat { 14 }
    public var space16: CGFloat { 16 }
    public var space20: CGFloat { 20 }
    public var space22: CGFloat { 22 }
    public var space24: CGFloat { 24 }
    public var space26: CGFloat { 26 }
    public var space30: CGFloat { 30 }
    public var space32: CGFloat { 32 }
    public var space36: CGFloat { 36 }
    public var space48: CGFloat { 48 }
    
    public var space100: CGFloat { 100 }

    public var radius4: CGFloat { 4 }
    public var radius8: CGFloat { 8 }
}

public struct GridWrapper<Base>: Grid {
    private let base: Base
    init(_ base: Base) {
        self.base = base
    }
}

public protocol GridCompatible: AnyObject {}

extension GridCompatible {
    public var grid: GridWrapper<Self> { GridWrapper(self) }
}

extension UIView: GridCompatible {}
extension UIViewController: GridCompatible {}

extension View {
    public var grid: GridWrapper<Self> { GridWrapper(self) }
}
