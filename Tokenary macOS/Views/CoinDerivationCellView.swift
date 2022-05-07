// Copyright © 2022 Tokenary. All rights reserved.

import Cocoa

protocol CoinDerivationCellDelegate: AnyObject {
    func didToggleCheckmark(_ sender: NSTableRowView)
}

class CoinDerivationCellView: NSTableRowView {
    
    @IBOutlet weak var checkBox: NSButton!
    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var logoImageView: NSImageView! {
        didSet {
            logoImageView.wantsLayer = true
            logoImageView.layer?.cornerRadius = 10
            logoImageView.layer?.masksToBounds = true
        }
    }
    
    private weak var cellDelegate: CoinDerivationCellDelegate?
    
    func setup(title: String, image: NSImage, isEnabled: Bool, delegate: CoinDerivationCellDelegate) {
        cellDelegate = delegate
        titleTextField.stringValue = title
        logoImageView.image = image
        setCheckBox(enabled: isEnabled)
    }
    
    func toggle() {
        setCheckBox(enabled: checkBox.state != .on)
    }
    
    @IBAction func didToggleCheckmark(_ sender: Any) {
        cellDelegate?.didToggleCheckmark(self)
    }
    
    private func setCheckBox(enabled: Bool) {
        checkBox.state = enabled ? .on : .off
    }
    
}
