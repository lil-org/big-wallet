// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class MultilineLabelTableViewCell: UITableViewCell {

    @IBOutlet weak var multilineLabel: UILabel!
    
    func setup(text: String, largeFont: Bool) {
        multilineLabel.text = text
        multilineLabel.font = largeFont ? UIFont.systemFont(ofSize: 21, weight: .medium) : UIFont.systemFont(ofSize: 17, weight: .regular)
    }
    
}
