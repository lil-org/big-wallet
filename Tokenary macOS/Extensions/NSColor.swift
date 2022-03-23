// Copyright © 2021 Tokenary. All rights reserved.

import AppKit

extension NSColor {
    
    static let inkGreen = NSColor(named: "InkGreen")!
    
    convenience init(
        light lightModeColor: @escaping @autoclosure () -> NSColor,
        dark darkModeColor: @escaping @autoclosure () -> NSColor
     ) {
         self.init(name: nil) { appearance in
             switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
             case .some(.darkAqua):
                 return darkModeColor()
             default:
                 return lightModeColor()
             }
         }
    }
}
