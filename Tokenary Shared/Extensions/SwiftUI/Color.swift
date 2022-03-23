// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
#if canImport(UIKit)
    import UIKit
    typealias BridgedColor = UIColor
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    typealias BridgedColor = NSColor
#endif

extension Color {
    init(
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
    static var inkGreen = Color(UIColor.inkGreen)
    static var systemGray2 = Color(UIColor.systemGray2)
    static var systemGray3 = Color(UIColor.systemGray3)
    static var systemGray4 = Color(UIColor.systemGray4)
    static var systemGray5 = Color(UIColor.systemGray5)
    static var systemGray6 = Color(UIColor.systemGray6)
    static var secondarySystemBackground = Color(UIColor.secondarySystemBackground)
#elseif canImport(AppKit)
    static var inkGreen = Color(NSColor.inkGreen)
    static var systemGray1 = Color(
        light: Color(
            red: 174 / 255,
            green: 174 / 255,
            blue: 178 / 255
        ), dark: Color(
            red: 99 / 255,
            green: 99 / 255,
            blue: 102 / 255
        )
    )
    static var systemGray2 = Color(
        light: Color(
            red: 199 / 255,
            green: 199 / 255,
            blue: 204 / 255
        ), dark: Color(
            red: 72 / 255,
            green: 72 / 255,
            blue: 74 / 255
        )
    )
    static var systemGray3 = Color(
        light: Color(
            red: 209 / 255,
            green: 209 / 255,
            blue: 214 / 255
        ), dark: Color(
            red: 58 / 255,
            green: 58 / 255,
            blue: 58 / 255
        )
    )
    static var systemGray4 = Color(
        light: Color(
            red: 209 / 255,
            green: 209 / 255,
            blue: 214 / 255
        ), dark: Color(
            red: 58 / 255,
            green: 58 / 255,
            blue: 60 / 255
        )
    )
    static var systemGray5 = Color(
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
    static var systemGray6 = Color(
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
    static var secondarySystemBackground = Color(NSColor.controlBackgroundColor)
#endif
    static var systemPink = Color(BridgedColor.systemPink)
    static var systemRed = Color(BridgedColor.systemRed)
    static var systemGray = Color(
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
