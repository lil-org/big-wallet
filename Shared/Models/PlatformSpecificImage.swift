// ∅ 2025 lil org

import Foundation

#if os(iOS)
import UIKit
public typealias PlatformSpecificImage = UIImage
#elseif os(macOS)
import Cocoa
public typealias PlatformSpecificImage = NSImage
#endif
