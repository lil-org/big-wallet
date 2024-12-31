// ∅ 2025 lil org

import UIKit

protocol PreviewAccountTableViewCellDelegate: AnyObject {
    func didToggleSwitch(_ sender: PreviewAccountTableViewCell)
}

class PreviewAccountTableViewCell: UITableViewCell {

    @IBOutlet weak var coinSwitch: UISwitch!
    private weak var cellDelegate: PreviewAccountTableViewCellDelegate?
    @IBOutlet weak var logoImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var indexLabel: UILabel!
    
    func setup(title: String, image: UIImage?, index: Int, isEnabled: Bool, delegate: PreviewAccountTableViewCellDelegate) {
        cellDelegate = delegate
        logoImageView.image = image
        titleLabel.text = title
        coinSwitch.isOn = isEnabled
        indexLabel.text = String(index)
    }
    
    func toggle() {
        coinSwitch.isOn.toggle()
    }
    
    @IBAction func didToggleSwitch(_ sender: Any) {
        cellDelegate?.didToggleSwitch(self)
    }
    
}
