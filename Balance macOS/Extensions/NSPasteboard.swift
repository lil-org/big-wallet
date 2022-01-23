// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

extension NSPasteboard {
    
    func clearAndSetString(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
    
}
