// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class MultilineLabelTableViewCell: UITableViewCell {

    @IBOutlet weak var multilineLabel: UILabel!
    
    func setup(text: String) {
        multilineLabel.text = text
    }
    
}
