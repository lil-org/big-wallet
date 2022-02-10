import UIKit
import SparrowKit
import NativeUIKit

class BlockiesAddressTableViewCell: SPTableViewCell {
    let avatarView = NativeAvatarView().do {
        $0.isEditable = false
    }
    
    let addressLabel = SPLabel().do {
        $0.font = .preferredFont(forTextStyle: .title3, weight: .medium).monospaced
        $0.textColor = .label
        $0.minimumScaleFactor = 0.1
        $0.adjustsFontSizeToFitWidth = true
        $0.numberOfLines = 2
    }
    
    override func commonInit() {
        super.commonInit()
        accessoryType = .disclosureIndicator
        contentView.addSubviews(avatarView, addressLabel)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        avatarView.frame = .init(side: 35)
        avatarView.frame.origin.x = contentView.layoutMargins.left
        avatarView.setYCenter()
        
        addressLabel.layoutDynamicHeight(
            x: avatarView.frame.maxX + NativeLayout.Spaces.default_less,
            y: contentView.layoutMargins.top,
            width: layoutWidth - avatarView.frame.width - NativeLayout.Spaces.default_less)
        
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let superSize = super.sizeThatFits(size)
        return .init(width: superSize.width, height: addressLabel.frame.maxY + contentView.layoutMargins.bottom)
    }
}
