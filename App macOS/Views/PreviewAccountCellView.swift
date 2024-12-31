// ∅ 2025 lil org

import Cocoa

protocol PreviewAccountCellDelegate: AnyObject {
    func didToggleCheckmark(_ sender: NSTableRowView)
}

class PreviewAccountCellView: NSTableRowView {
    
    @IBOutlet weak var indexLabel: NSTextField!
    @IBOutlet weak var checkBox: NSButton!
    @IBOutlet weak var titleTextField: NSTextField!
    @IBOutlet weak var logoImageView: NSImageView! {
        didSet {
            logoImageView.wantsLayer = true
            logoImageView.layer?.cornerRadius = 10
            logoImageView.layer?.masksToBounds = true
        }
    }
    
    private weak var cellDelegate: PreviewAccountCellDelegate?
    
    func setup(title: String, index: Int, image: NSImage?, isEnabled: Bool, delegate: PreviewAccountCellDelegate) {
        cellDelegate = delegate
        titleTextField.stringValue = title
        indexLabel.stringValue = String(index)
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
