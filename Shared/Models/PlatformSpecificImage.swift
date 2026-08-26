// ∅ 2026 lil org

#if os(iOS) || os(visionOS)
import UIKit
typealias PlatformSpecificImage = UIImage
#elseif os(macOS)
import Cocoa
typealias PlatformSpecificImage = NSImage
#endif

extension PlatformSpecificImage {

    var pngDataRepresentation: Data? {
#if os(iOS) || os(visionOS)
        return pngData()
#elseif os(macOS)
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = size
        return bitmap.representation(using: .png, properties: [:])
#endif
    }

}
