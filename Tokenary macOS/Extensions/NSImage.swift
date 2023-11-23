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
    
    func with(pointSize: CGFloat, weight: NSFont.Weight, color: NSColor? = nil) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let color = color {
            return withSymbolConfiguration(configuration)?.tinted(color)
        } else {
            return withSymbolConfiguration(configuration)
        }
    }
    
    func withCornerRadius(_ cornerRadius: CGFloat) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return self }
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        draw(in: rect)
        newImage.unlockFocus()
        return newImage
    }
    
}
