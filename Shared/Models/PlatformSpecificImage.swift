// ∅ 2026 lil org

#if os(iOS) || os(visionOS)
import UIKit
typealias PlatformSpecificImage = UIImage
#elseif os(macOS)
import Cocoa
typealias PlatformSpecificImage = NSImage
#endif
