// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class Alert: NSAlert {
    
    override func runModal() -> NSApplication.ModalResponse {
        defer {
            Agent.shared.statusBarButtonIsBlocked = false
        }
        Agent.shared.statusBarButtonIsBlocked = true
        return super.runModal()
    }
    
}
