// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension NSImage {
    func pngData() -> Data? {
        guard
            let tiffRepresentation = tiffRepresentation,
            let bitmapImage = NSBitmapImageRep(data: tiffRepresentation)
        else { return nil }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}
