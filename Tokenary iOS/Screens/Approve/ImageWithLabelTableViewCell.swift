// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import Kingfisher

class ImageWithLabelTableViewCell: UITableViewCell {

    @IBOutlet weak var iconImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    
    func setup(text: String, imageURL: String?, image: UIImage?) {
        titleLabel.text = text
        if let image = image {
            iconImageView.image = image
            iconImageView.layer.cornerRadius = 15
            iconImageView.tintColor = .secondaryLabel
        } else if let urlString = imageURL, let url = URL(string: urlString) {
            iconImageView.kf.setImage(with: url)
            iconImageView.tintColor = .secondarySystemFill
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView.kf.cancelDownloadTask()
        iconImageView.image = Images.circleFill
        iconImageView.layer.cornerRadius = 0
        iconImageView.tintColor = .secondarySystemFill
    }
    
}
