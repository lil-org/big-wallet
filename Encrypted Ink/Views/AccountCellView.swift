// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import BlockiesSwift

class AccountCellView: NSTableRowView {
    
    @IBOutlet weak var addressImageView: NSImageView! {
        didSet {
            addressImageView.wantsLayer = true
            addressImageView.layer?.cornerRadius = 15
            addressImageView.layer?.masksToBounds = true
        }
    }
    @IBOutlet weak var addressTextField: NSTextField!
    
    func setup(address: String) {
        addressImageView.image = Blockies(seed: address).createImage()
        let without0x = address.dropFirst(2)
        addressTextField.stringValue = without0x.prefix(4) + "..." + without0x.suffix(4)
    }
    
}
