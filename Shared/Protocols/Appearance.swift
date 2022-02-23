// Copyright © 2022 Tokenary. All rights reserved.
// Special-purpose protocol that holds appearance-related constants(like colors, font-sized, etc.)

import SwiftUI
import UIKit

public protocol Appearance {}

extension Appearance {
    public var zero: Int { .zero }
    public var maxPercent: CGFloat { 1 }
    public var defaultAnimationDuration: TimeInterval { 0.3 }
}

public struct AppearanceWrapper<Base>: Appearance {
    private let base: Base
    init(_ base: Base) {
        self.base = base
    }
}

public protocol AppearanceCompatible: AnyObject {}

extension AppearanceCompatible {
    public var appearance: AppearanceWrapper<Self> { AppearanceWrapper(self) }
}

extension UIView: AppearanceCompatible {}
extension UIViewController: AppearanceCompatible {}

extension View {
    public var appearance: AppearanceWrapper<Self> { AppearanceWrapper(self) }
}
