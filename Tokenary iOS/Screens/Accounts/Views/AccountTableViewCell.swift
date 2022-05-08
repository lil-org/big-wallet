// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import BlockiesSwift

protocol AccountTableViewCellDelegate: AnyObject {
    
    func didTapMoreButton(accountCell: AccountTableViewCell)
    
}

class AccountTableViewCell: UITableViewCell {

    private weak var cellDelegate: AccountTableViewCellDelegate?
    @IBOutlet weak var avatarImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    
    func setup(title: String, image: UIImage?, delegate: AccountTableViewCellDelegate) {
        cellDelegate = delegate
        avatarImageView.image = image
        titleLabel.text = title
    }
    
    @IBAction func moreButtonTapped(_ sender: Any) {
        cellDelegate?.didTapMoreButton(accountCell: self)
    }
    
}
