// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
import BlockiesSwift
import WalletCore

class AccountCellView: NSTableRowView {
    
    @IBOutlet weak var addressImageView: NSImageView! {
        didSet {
            addressImageView.wantsLayer = true
            addressImageView.layer?.cornerRadius = 15
            addressImageView.layer?.masksToBounds = true
        }
    }
    @IBOutlet weak var addressTextField: NSTextField!
    
    func setup(account: Account) {
        addressImageView.image = account.image
        addressTextField.stringValue = account.croppedAddress
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
