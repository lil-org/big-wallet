// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class RightClickTableView: NSTableView {
    
    weak var menuSource: TableViewMenuSource?
    var deselectedRow = -1
    
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        if index >= 0, let menu = menuSource?.menuForRow(index) {
            selectRowIndexes([index], byExtendingSelection: true)
            return menu
        } else {
            return nil
        }
    }
    
}

protocol TableViewMenuSource: AnyObject {
    
    func menuForRow(_ row: Int) -> NSMenu?
    
}
