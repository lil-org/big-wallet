// ∅ 2026 lil org

import Cocoa

class AccountCellView: NSTableRowView {

    private var showsAccountSelection = false
    
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
    
    func setup(account: WalletAccount, walletId: String, isSelected: Bool, isDisabled: Bool, showsAccountSelection: Bool = false) {
        self.showsAccountSelection = showsAccountSelection
        addressImageView.image = account.image
        addressTextField.stringValue = account.nameOrCroppedAddress(walletId: walletId)
        setSelected(isSelected)
        setDisabled(isDisabled)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        showsAccountSelection ? .normal : super.interiorBackgroundStyle
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard showsAccountSelection else {
            super.drawSelection(in: dirtyRect)
            return
        }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        outline.lineWidth = 2
        outline.stroke()
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
        backgroundColor = .systemBlue.withAlphaComponent(0.4)
        NSAnimationContext.runAnimationGroup { [weak self] context in
            context.duration = 1.2
            context.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
            self?.animator().backgroundColor = initialBackgroundColor
        }
    }
    
}
