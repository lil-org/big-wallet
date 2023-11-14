// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class MultilineLabelTableViewCell: UITableViewCell {

    @IBOutlet weak var multilineLabel: UILabel!
    
    func setup(text: String, largeFont: Bool, oneLine: Bool, pro: Bool) {
        multilineLabel.text = text
        
        if pro {
            multilineLabel.textColor = .secondaryLabel
            multilineLabel.font = UIFont.italicSystemFont(ofSize: 17)
        } else if largeFont {
            multilineLabel.textColor = .label
            multilineLabel.font = largeFont ? UIFont.systemFont(ofSize: 21, weight: .medium) : UIFont.systemFont(ofSize: 17, weight: .regular)
        }
        
        multilineLabel.numberOfLines = oneLine ? 1 : 0
        multilineLabel.lineBreakMode = oneLine ? .byTruncatingTail : .byCharWrapping
    }
    
}
