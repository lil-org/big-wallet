// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import BlockiesSwift

protocol AccountTableViewCellDelegate: AnyObject {
    
    func didTapMoreButton(accountCell: AccountTableViewCell)
    
}

class AccountTableViewCell: UITableViewCell {

    private weak var cellDelegate: AccountTableViewCellDelegate?
    
    @IBOutlet weak var moreButton: UIButton!
    @IBOutlet weak var avatarImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    
    func setup(title: String, image: UIImage?, isDisabled: Bool, customSelectionStyle: Bool, isSelected: Bool, delegate: AccountTableViewCellDelegate) {
        selectionStyle = customSelectionStyle ? .none : .blue
        
        cellDelegate = delegate
        avatarImageView.image = image
        titleLabel.text = title
        setDisabled(isDisabled)
        
        if isDisabled {
            backgroundColor = .secondarySystemGroupedBackground.withAlphaComponent(alpha)
        } else if isSelected {
            backgroundColor = .tintColor
        } else {
            backgroundColor = .secondarySystemGroupedBackground
        }
    }
    
    private func setDisabled(_ disabled: Bool) {
        let alpha: CGFloat = disabled ? 0.35 : 1
        contentView.alpha = alpha
    }
    
    @IBAction func moreButtonTapped(_ sender: Any) {
        cellDelegate?.didTapMoreButton(accountCell: self)
    }
    
}
