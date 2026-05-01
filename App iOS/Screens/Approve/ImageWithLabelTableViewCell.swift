// ∅ 2026 lil org

import UIKit

class ImageWithLabelTableViewCell: UITableViewCell {

    @IBOutlet weak var iconImageView: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var extraTitleLabel: UILabel!
    
    func setup(text: String, extraText: String?, imageURL: String?, image: UIImage?) {
        titleLabel.text = text
        extraTitleLabel.text = extraText
        if let image = image {
            iconImageView.image = image
            iconImageView.layer.cornerRadius = 15
            iconImageView.tintColor = .secondaryLabel
        } else if let urlString = imageURL, let url = URL(string: urlString) {
            iconImageView.setRemoteImage(with: url)
            iconImageView.tintColor = .secondarySystemFill
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView.cancelRemoteImageLoad()
        iconImageView.image = Images.circleFill
        iconImageView.layer.cornerRadius = 0
        iconImageView.tintColor = .secondarySystemFill
    }
    
}
