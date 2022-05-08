// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

protocol AccountsHeaderViewDelegate: AnyObject {
    func didTapEditButton(_ sender: AccountsHeaderView, sectionIndex: Int)
}

class AccountsHeaderView: UITableViewHeaderFooterView {

    @IBOutlet weak var invisibleButton: UIButton!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var editSectionButton: UIButton!
    private weak var cellDelegate: AccountsHeaderViewDelegate?
    private var sectionIndex = 0
    
    func set(title: String, showsButton: Bool, sectionIndex: Int, delegate: AccountsHeaderViewDelegate) {
        titleLabel.text = title.uppercased()
        editSectionButton.isHidden = !showsButton
        invisibleButton.isHidden = !showsButton
        cellDelegate = delegate
        self.sectionIndex = sectionIndex
    }
    
    @IBAction func editSectionButtonTapped(_ sender: Any) {
        cellDelegate?.didTapEditButton(self, sectionIndex: sectionIndex)
    }
    
}
