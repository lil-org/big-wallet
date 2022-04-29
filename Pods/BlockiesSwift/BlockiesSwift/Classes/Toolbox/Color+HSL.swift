//
//  Color+HSL.swift
//  BlockiesSwift
//
//  Created by Koray Koska on 22.12.17.
//

#if os(iOS) || os(tvOS) || os(watchOS)
    import UIKit
#elseif os(OSX)
    import AppKit
#endif

#if os(iOS) || os(tvOS) || os(watchOS)
    typealias Color = UIColor
#elseif os(OSX)
    typealias Color = NSColor
#endif

extension Color {

    /**
     * Initializes Color with the given HSL color values.
     *
     * H must be bigger than 0 and smaller than 360.
     *
     * S must be between 0 and 1.
     *
     * L must be between 0 and 1.
     *
     * - parameter h: The h value.
     * - parameter s: The s value.
     * - parameter l: The l value.
     */
    convenience init?(h: Double, s: Double, l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - (c / 2)

        let (tmpR, tmpG, tmpB): (Double, Double, Double)
        if 0 <= h && h < 60 {
            (tmpR, tmpG, tmpB) = (c, x, 0)
        } else if 60 <= h && h < 120 {
            (tmpR, tmpG, tmpB) = (x, c, 0)
        } else if 120 <= h && h < 180 {
            (tmpR, tmpG, tmpB) = (0, c, x)
        } else if 180 <= h && h < 240 {
            (tmpR, tmpG, tmpB) = (0, x, c)
        } else if 240 <= h && h < 300 {
            (tmpR, tmpG, tmpB) = (x, 0, c)
        } else if 300 <= h && h < 360 {
            (tmpR, tmpG, tmpB) = (c, 0, x)
        } else {
            return nil
        }

        let r = (tmpR + m)
        let g = (tmpG + m)
        let b = (tmpB + m)

        self.init(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    static func fromHSL(h: Double, s: Double, l: Double) -> Color? {
        return Color(h: h, s: s, l: l)
    }
}
