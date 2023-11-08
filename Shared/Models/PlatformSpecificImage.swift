// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

#if os(iOS)
import UIKit
public typealias PlatformSpecificImage = UIImage
#elseif os(macOS)
import Cocoa
public typealias PlatformSpecificImage = NSImage
#endif
