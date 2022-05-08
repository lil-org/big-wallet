// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

protocol CoinDerivationTableViewCellDelegate: AnyObject {
    
    func didToggleSwitch(_ sender: CoinDerivationTableViewCell)
    
}

class CoinDerivationTableViewCell: UITableViewCell {

    @IBOutlet weak var coinSwitch: UISwitch!
    private weak var cellDelegate: CoinDerivationTableViewCellDelegate?
    @IBOutlet weak var logoImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    
    func setup(coinDerivation: CoinDerivation, isEnabled: Bool, delegate: CoinDerivationTableViewCellDelegate) {
        cellDelegate = delegate
        logoImageView.image = Images.logo(coin: coinDerivation.coin)
        titleLabel.text = coinDerivation.title
        coinSwitch.isOn = isEnabled
    }
    
    func toggle() {
        coinSwitch.isOn.toggle()
    }
    
    @IBAction func didToggleSwitch(_ sender: Any) {
        cellDelegate?.didToggleSwitch(self)
    }
    
}
