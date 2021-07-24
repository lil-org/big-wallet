// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class NewAccountOptionCellView: NSTableRowView {

    @IBOutlet weak var titleLabel: NSTextField!
    
    func setup(title: String) {
        titleLabel.stringValue = title
    }
    
}
