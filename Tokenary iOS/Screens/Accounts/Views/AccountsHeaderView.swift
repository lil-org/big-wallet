// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

protocol AccountsHeaderViewDelegate: AnyObject {
    func didTapEditButton(_ sender: AccountsHeaderView)
}

class AccountsHeaderView: UITableViewHeaderFooterView {

    @IBOutlet weak var invisibleButton: UIButton!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var editSectionButton: UIButton!
    private weak var cellDelegate: AccountsHeaderViewDelegate?
    
    func set(title: String, showsButton: Bool, delegate: AccountsHeaderViewDelegate) {
        titleLabel.text = title
        editSectionButton.isHidden = !showsButton
        invisibleButton.isHidden = !showsButton
        cellDelegate = delegate
    }
    
    @IBAction func editSectionButtonTapped(_ sender: Any) {
        cellDelegate?.didTapEditButton(self)
    }
    
}
