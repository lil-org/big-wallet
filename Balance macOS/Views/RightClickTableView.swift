// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class RightClickTableView: NSTableView {
    
    var deselectedRow = -1
    var shouldShowRightClickMenu = true
    
    override func menu(for event: NSEvent) -> NSMenu? {
        guard shouldShowRightClickMenu else { return nil }
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
