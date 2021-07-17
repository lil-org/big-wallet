// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class RightClickTableView: NSTableView {
    
    var deselectedRow = -1
    
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        if index >= 0 {
            selectRowIndexes([index], byExtendingSelection: true)
            return menu
        } else {
            return nil
        }
    }
    
}
