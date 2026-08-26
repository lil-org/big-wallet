// ∅ 2026 lil org

import Cocoa

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
    
    func setup(account: WalletAccount, walletId: String) {
        addressImageView.image = account.image
        addressTextField.stringValue = account.nameOrCroppedAddress(walletId: walletId)
    }

    func blink() {
        let initialBackgroundColor = backgroundColor
        backgroundColor = .systemBlue.withAlphaComponent(0.4)
        NSAnimationContext.runAnimationGroup { [weak self] context in
            context.duration = 1.2
            context.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
            self?.animator().backgroundColor = initialBackgroundColor
        }
    }
    
}
