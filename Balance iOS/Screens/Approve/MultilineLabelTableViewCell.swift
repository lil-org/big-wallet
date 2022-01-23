// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class MultilineLabelTableViewCell: UITableViewCell {

    @IBOutlet weak var multilineLabel: UILabel!
    
    func setup(text: String, largeFont: Bool, oneLine: Bool) {
        multilineLabel.text = text
        multilineLabel.font = largeFont ? UIFont.systemFont(ofSize: 21, weight: .medium) : UIFont.systemFont(ofSize: 17, weight: .regular)
        multilineLabel.numberOfLines = oneLine ? 1 : 0
    }
    
}
