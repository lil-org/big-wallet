// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
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
    
    override func awakeFromNib() {
        super.awakeFromNib()
        wantsLayer = true
    }
    
    func setup(account: Account, isSelected: Bool, isDisabled: Bool) {
        addressImageView.image = account.image
        addressTextField.stringValue = account.croppedAddress
        setSelected(isSelected)
        setDisabled(isDisabled)
    }
    
    private func setDisabled(_ disabled: Bool) {
        addressImageView.alphaValue = disabled ? 0.4 : 1
        addressTextField.alphaValue = disabled ? 0.4 : 1
    }
    
    private func setSelected(_ selected: Bool) {
        layer?.backgroundColor = (selected ? NSColor.selectedContentBackgroundColor : NSColor.clear).cgColor
        addressTextField.textColor = selected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
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
