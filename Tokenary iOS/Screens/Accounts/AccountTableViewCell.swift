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
    
    func setup(address: String, delegate: AccountTableViewCellDelegate) {
        cellDelegate = delegate
        avatarImageView.image = Blockies(seed: address.lowercased()).createImage()
        let without0x = address.dropFirst(2)
        titleLabel.text = without0x.prefix(4) + "..." + without0x.suffix(4)
    }
    
    @IBAction func moreButtonTapped(_ sender: Any) {
        cellDelegate?.didTapMoreButton(accountCell: self)
    }
    
}
