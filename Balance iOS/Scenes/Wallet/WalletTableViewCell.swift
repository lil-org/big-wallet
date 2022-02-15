import UIKit
import SparrowKit
import NativeUIKit

class WalletTableViewCell: SPTableViewCell {
    
    let avatarView = NativeAvatarView().do {
        $0.isEditable = false
    }
    
    let titleLabel = SPLabel().do {
        $0.font = UIFont.preferredFont(forTextStyle: .title3, weight: .semibold).rounded
        $0.textColor = .label
    }
    
    let addressLabel = SPLabel().do {
        $0.font = UIFont.preferredFont(forTextStyle: .body, weight: .regular, addPoints: -2).monospaced
        $0.textColor = .secondaryLabel
    }
    
    override func commonInit() {
        super.commonInit()
        accessoryType = .disclosureIndicator
        contentView.addSubviews(avatarView, titleLabel, addressLabel)
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        addressLabel.text = nil
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        avatarView.frame = .init(side: 35)
        avatarView.frame.origin.x = contentView.layoutMargins.left
        let leftSpace: CGFloat = NativeLayout.Spaces.default_less
        let labelsWidth = contentView.frame.width - avatarView.frame.maxX - layoutMargins.right - leftSpace
        titleLabel.layoutDynamicHeight(x: avatarView.frame.maxX + leftSpace, y: contentView.layoutMargins.top, width: layoutWidth)
        addressLabel.layoutDynamicHeight(x: titleLabel.frame.origin.x, y: titleLabel.frame.maxY + 2, width: labelsWidth)
        avatarView.setYCenter()
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let superSize = super.sizeThatFits(size)
        return .init(width: superSize.width, height: addressLabel.frame.maxY + contentView.layoutMargins.bottom)
    }
}
