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
        let address = account.address
        
        if account.coin == .ethereum {
            addressImageView.image = Blockies(seed: address.lowercased()).createImage()
        } else {
            addressImageView.image = Images.logo(coin: account.coin)
        }
        
        let without0x = account.coin == .ethereum ? String(address.dropFirst(2)) : address
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
