// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

class AddAccountOptionCellView: NSTableRowView {

    @IBOutlet weak var titleLabel: NSTextField!
    
    func setup(title: String) {
        titleLabel.stringValue = title
    }
    
}
