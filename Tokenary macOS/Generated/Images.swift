// Copyright © 2022 Tokenary. All rights reserved.

import AppKit

// ToDo(@pettrk): Generate this
struct Images {
    
    static var status: NSImage { named("status") }
    
    private static func named(_ name: String) -> NSImage {
        return NSImage(named: name)!
    }
}
