// Copyright © 2021 Tokenary. All rights reserved.

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
        addressImageView.image = Blockies(seed: address.lowercased()).createImage()
        let without0x = address.dropFirst(2)
        addressTextField.stringValue = without0x.prefix(4) + "..." + without0x.suffix(4)
    }
    
    func blink() {
        let initialBackgroundColor = backgroundColor
        backgroundColor = .inkGreen
        NSAnimationContext.runAnimationGroup { [weak self] context in
            context.duration = 1.2
            context.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
            self?.animator().backgroundColor = initialBackgroundColor
        }
    }
    
}
