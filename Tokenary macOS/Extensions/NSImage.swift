// Copyright © 2022 Tokenary. All rights reserved.

import Cocoa

extension NSImage {
    
    func tinted(_ tintColor: NSColor) -> NSImage {
        guard isTemplate else { return self }
        lockFocus()
        tintColor.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        unlockFocus()
        isTemplate = false
        return self
    }
    
}
