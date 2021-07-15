// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

extension NSPasteboard {
    
    func clearAndSetString(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
    
}
