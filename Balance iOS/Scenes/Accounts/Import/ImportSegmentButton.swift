import UIKit
import SparrowKit
import NativeUIKit

class ImportSegmentButton: SPButton {
    
    var appearance: Appearnce = .default {
        didSet {
            switch appearance {
            case .`default`:
                borderWidth = .zero
                checkmarkIconView.image = .system("circle")
            case .selected:
                borderWidth = 2.5
                checkmarkIconView.image = .init(.checkmark.circleFill)
            }
        }
    }
    
    let checkmarkIconView = SPImageView().do {
        $0.contentMode = .scaleAspectFit
    }
    
    let iconView = SPImageView().do {
        $0.backgroundColor = .secondarySystemBackground
        $0.roundCorners(radius: 8)
    }
    
    let headerLabel = SPLabel().do {
        $0.numberOfLines = 0
        $0.font = UIFont.preferredFont(forTextStyle: .body, weight: .semibold, addPoints: 2)
    }
    
    let descriptionLabel = SPLabel().do {
        $0.numberOfLines = 0
        $0.font = UIFont.preferredFont(forTextStyle: .body, weight: .regular)
    }
    
    override func commonInit() {
        super.commonInit()
        backgroundColor = .secondarySystemGroupedBackground
        roundCorners(radius: 14)
        layoutMargins = .init(horizontal: NativeLayout.Spaces.default_more, vertical: NativeLayout.Spaces.default_more)
        headerLabel.text = "Title"
        descriptionLabel.text = "Subtitle"
        addSubviews(iconView, headerLabel, descriptionLabel, checkmarkIconView)
        addShadow(ofColor: .black, radius: 8, offset: .init(width: .zero, height: 12), opacity: 0.1)
    }
    
    override func tintColorDidChange() {
        super.tintColorDidChange()
        borderColor = self.tintColor
        checkmarkIconView.tintColor = .tint
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        iconView.frame = .init(side: 60)
        iconView.frame.origin = .init(x: layoutMargins.left, y: layoutMargins.top)
        
        checkmarkIconView.frame = .init(side: 24)
        checkmarkIconView.frame.origin.y = iconView.frame.origin.y
        checkmarkIconView.setMaxXToSuperviewRightMargin()
        
        let width = layoutWidth - checkmarkIconView.frame.width
        headerLabel.layoutDynamicHeight(x: layoutMargins.left, y: iconView.frame.maxY + NativeLayout.Spaces.default_less, width: width)
        descriptionLabel.layoutDynamicHeight(x: headerLabel.frame.origin.x, y: headerLabel.frame.maxY + 3, width: headerLabel.frame.width)
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        return .init(width: size.width, height: descriptionLabel.frame.maxY + layoutMargins.bottom)
    }
    
    enum Appearnce {
        
        case `default`
        case selected
    }
}
