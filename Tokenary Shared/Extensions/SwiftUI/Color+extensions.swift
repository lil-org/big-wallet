// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
#if canImport(UIKit)
    import UIKit
    public typealias BridgedColor = UIColor
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    public typealias BridgedColor = NSColor
#endif

extension Color {
    public init(
        light lightModeColor: @escaping @autoclosure () -> Color,
        dark darkModeColor: @escaping @autoclosure () -> Color
    ) {
#if canImport(UIKit)
        let color = UIColor(
            light: UIColor(lightModeColor()), dark: UIColor(darkModeColor())
        )
#elseif canImport(AppKit)
        let color = NSColor(
            light: NSColor(lightModeColor()), dark: NSColor(darkModeColor())
        )
#endif
        self.init(color)
    }

#if canImport(UIKit)
    public static var inkGreen = Color(UIColor.inkGreen)
    public static var systemGray4 = Color(UIColor.systemGray4)
    public static var systemGray5 = Color(UIColor.systemGray5)
    public static var systemGray6 = Color(UIColor.systemGray6)
    public static var secondarySystemBackground = Color(UIColor.secondarySystemBackground)
#elseif canImport(AppKit)
    public static var inkGreen = Color(NSColor.inkGreen)
    public static var systemGray4 = Color(NSColor.lightGray)
    public static var systemGray5 = Color(
        light: Color(
            red: 229 / 255,
            green: 229 / 255,
            blue: 234 / 255
        ), dark: Color(
            red: 44 / 255,
            green: 44 / 255,
            blue: 56 / 255
        )
    )
    public static var systemGray6 = Color(
        light: Color(
            red: 242 / 255,
            green: 242 / 255,
            blue: 247 / 255
        ), dark: Color(
            red: 28 / 255,
            green: 28 / 255,
            blue: 30 / 255
        )
    )
    public static var secondarySystemBackground = Color(NSColor.controlBackgroundColor)
#endif
    public static var systemPink = Color(BridgedColor.systemPink)
    public static var systemRed = Color(BridgedColor.systemRed)
    
    public static var iconGray = Color(
        light: Color(
            red: 142 / 255,
            green: 142 / 255,
            blue: 147 / 255
        ), dark: Color(
            red: 142 / 255,
            green: 142 / 255,
            blue: 147 / 255
        )
    )
}
