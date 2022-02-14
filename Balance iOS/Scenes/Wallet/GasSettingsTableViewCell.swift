import UIKit
import SparrowKit
import NativeUIKit

class GasSettingsTableViewCell: SPTableViewCell {
    let label = SPLabel(text: "Gas Fee").do {
        $0.textColor = .label
    }
    
    var input: UITextFieldWithSuffix!
    
    override func commonInit() {
        super.commonInit()
        
        contentView.addSubviews(label, input)
        
        selectionStyle = .none
        accessoryType = .none
        
        input.suffix = "Gwei"
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        label.translatesAutoresizingMaskIntoConstraints = false
        label.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor).isActive = true
        label.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor).isActive = true
        label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor).isActive = true
        label.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5).isActive = true
        label.layoutDynamicHeight()
        
        input.translatesAutoresizingMaskIntoConstraints = false
        input.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor).isActive = true
        input.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor).isActive = true
        input.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor).isActive = true
        input.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5).isActive = true
        input.heightAnchor.constraint(equalTo: label.heightAnchor).isActive = true
        
        input.textAlignment = .right
        input.keyboardType = .numberPad
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let superSize = super.sizeThatFits(size)
        return .init(width: superSize.width, height: contentView.layoutMargins.bottom)
    }
}
