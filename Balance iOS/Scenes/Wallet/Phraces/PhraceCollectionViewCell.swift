import UIKit
import SPDiffable
import SparrowKit
import NativeUIKit

class PhraceCollectionViewCell: SPCollectionViewCell {
    
    let indexLabel = SPLabel().do {
        $0.font = UIFont.preferredFont(forTextStyle: .body, weight: .medium).monospaced
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 1
        $0.text = .space
    }
    
    let textLabel = SPLabel().do {
        $0.font = UIFont.preferredFont(forTextStyle: .title3, weight: .semibold).rounded
        $0.textColor = .label
        $0.numberOfLines = 1
        $0.text = .space
    }
    
    override func commonInit() {
        super.commonInit()
        contentView.layoutMargins = .init(horizontal: NativeLayout.Spaces.default_less, vertical: NativeLayout.Spaces.default_less)
        contentView.roundCorners(radius: 12)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.addSubviews(indexLabel, textLabel)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        indexLabel.layoutDynamicHeight(width: contentView.layoutWidth)
        textLabel.layoutDynamicHeight(width: contentView.layoutWidth)
        indexLabel.frame.origin.x = contentView.layoutMargins.left
        indexLabel.frame.origin.y = contentView.layoutMargins.top
        textLabel.frame.origin.x = indexLabel.frame.origin.x
        textLabel.frame.origin.y = indexLabel.frame.maxY + NativeLayout.Spaces.step
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        layoutSubviews()
        return .init(width: size.width, height: textLabel.frame.maxY + contentView.layoutMargins.bottom)
    }
}
