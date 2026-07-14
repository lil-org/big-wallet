// ∅ 2026 lil org

import UIKit

class ImageWithLabelTableViewCell: UITableViewCell {

    let iconImageView: UIImageView = {
        let imageView = UIImageView(image: Images.circleFill)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isOpaque = true
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .secondarySystemFill
        imageView.setContentHuggingPriority(UILayoutPriority(rawValue: 251), for: .horizontal)
        imageView.setContentHuggingPriority(UILayoutPriority(rawValue: 251), for: .vertical)
        return imageView
    }()

    let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isOpaque = false
        label.contentMode = .left
        label.text = "label"
        label.font = .systemFont(ofSize: 21, weight: .medium)
        label.textAlignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 0
        label.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        return label
    }()

    let extraTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isOpaque = false
        label.contentMode = .left
        label.text = "label"
        label.font = .systemFont(ofSize: 21)
        label.textColor = .tertiaryLabel
        label.textAlignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViewHierarchy()
    }
    
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

    private func setupViewHierarchy() {
        contentView.isOpaque = false
        contentView.clipsToBounds = true
        contentView.isMultipleTouchEnabled = true
        contentView.contentMode = .center
        separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)

        contentView.addSubview(titleLabel)
        contentView.addSubview(extraTitleLabel)
        contentView.addSubview(iconImageView)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.heightAnchor.constraint(equalToConstant: 30),
            iconImageView.widthAnchor.constraint(equalTo: iconImageView.heightAnchor),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 12),
            contentView.trailingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            extraTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            extraTitleLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            contentView.trailingAnchor.constraint(greaterThanOrEqualTo: extraTitleLabel.trailingAnchor, constant: 12)
        ])
    }
    
}
