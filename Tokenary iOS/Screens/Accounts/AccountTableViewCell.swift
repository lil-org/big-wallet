// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import BlockiesSwift

class AccountTableViewCell: UITableViewCell {

    @IBOutlet weak var avatarImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    
    func setup(address: String) {
        avatarImageView.image = Blockies(seed: address.lowercased()).createImage()
        let without0x = address.dropFirst(2)
        titleLabel.text = without0x.prefix(4) + "..." + without0x.suffix(4)
    }
    
}
