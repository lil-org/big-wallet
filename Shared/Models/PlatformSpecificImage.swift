// ∅ 2026 lil org

import Foundation

#if os(iOS) || os(visionOS)
import UIKit
public typealias PlatformSpecificImage = UIImage
#elseif os(macOS)
import Cocoa
public typealias PlatformSpecificImage = NSImage
#endif
