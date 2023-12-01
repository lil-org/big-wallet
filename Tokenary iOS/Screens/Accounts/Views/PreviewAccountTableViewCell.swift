// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

protocol PreviewAccountTableViewCellDelegate: AnyObject {
    func didToggleSwitch(_ sender: PreviewAccountTableViewCell)
}

class PreviewAccountTableViewCell: UITableViewCell {

    @IBOutlet weak var coinSwitch: UISwitch!
    private weak var cellDelegate: PreviewAccountTableViewCellDelegate?
    @IBOutlet weak var logoImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    
    func setup(title: String, image: UIImage?, isEnabled: Bool, delegate: PreviewAccountTableViewCellDelegate) {
        cellDelegate = delegate
        logoImageView.image = image
        titleLabel.text = title
        coinSwitch.isOn = isEnabled
    }
    
    func toggle() {
        coinSwitch.isOn.toggle()
    }
    
    @IBAction func didToggleSwitch(_ sender: Any) {
        cellDelegate?.didToggleSwitch(self)
    }
    
}
