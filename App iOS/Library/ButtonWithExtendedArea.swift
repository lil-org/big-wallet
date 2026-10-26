import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

class ButtonWithExtendedArea: UIButton {
    
    var minimumHitArea = CGSize(width: 60, height: 60)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isHidden || !isUserInteractionEnabled || alpha < 0.01 { return nil }
        
        let buttonSize = bounds.size
        let widthToAdd = max(minimumHitArea.width - buttonSize.width, 0)
        let heightToAdd = max(minimumHitArea.height - buttonSize.height, 0)
        let largerFrame = bounds.insetBy(dx: -widthToAdd / 2, dy: -heightToAdd / 2)
        
        return (largerFrame.contains(point)) ? self : nil
    }
    
}
