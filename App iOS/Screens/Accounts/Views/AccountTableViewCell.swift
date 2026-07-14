// ∅ 2026 lil org

import UIKit

protocol AccountTableViewCellDelegate: AnyObject {
    
    func didTapMoreButton(accountCell: AccountTableViewCell)
    
}

class AccountTableViewCell: UITableViewCell {

    private weak var cellDelegate: AccountTableViewCellDelegate?
    private let disabledAlpha: CGFloat = 0.35

    let moreButton: UIButton = ButtonWithExtendedArea(type: .system)
    let avatarImageView = UIImageView()
    let titleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }
    
    func setup(title: String, image: UIImage?, isDisabled: Bool, customSelectionStyle: Bool, isSelected: Bool, delegate: AccountTableViewCellDelegate) {
        selectionStyle = customSelectionStyle ? .none : .blue
        
        cellDelegate = delegate
        avatarImageView.image = image
        titleLabel.text = title
        setDisabled(isDisabled)
        
        if isDisabled {
            backgroundColor = .secondarySystemGroupedBackground.withAlphaComponent(disabledAlpha)
        } else if isSelected {
            backgroundColor = .tintColor
        } else {
            backgroundColor = .secondarySystemGroupedBackground
        }
        
        titleLabel.textColor = isSelected ? .white : .label
        moreButton.tintColor = isSelected ? .white : .tintColor
    }
    
    private func setDisabled(_ disabled: Bool) {
        contentView.alpha = disabled ? disabledAlpha : 1
    }
    
    @IBAction func moreButtonTapped(_ sender: Any) {
        cellDelegate?.didTapMoreButton(accountCell: self)
    }

    private func configureView() {
        selectionStyle = .blue
        separatorInset = UIEdgeInsets(top: 0, left: 58, bottom: 0, right: 0)

        contentView.isOpaque = false
        contentView.clipsToBounds = true
        contentView.isMultipleTouchEnabled = true
        contentView.contentMode = .center

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.clipsToBounds = true
        avatarImageView.contentMode = .scaleAspectFit
        avatarImageView.layer.cornerRadius = 15
        avatarImageView.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        avatarImageView.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isOpaque = false
        titleLabel.text = "label"
        titleLabel.contentMode = .left
        titleLabel.font = .systemFont(ofSize: 21, weight: .medium)
        titleLabel.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        titleLabel.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)

        var buttonConfiguration = UIButton.Configuration.plain()
        buttonConfiguration.title = ""
        buttonConfiguration.image = UIImage(systemName: "ellipsis.circle")
        buttonConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: .systemFont(ofSize: 17))
        moreButton.configuration = buttonConfiguration
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.addTarget(self, action: #selector(moreButtonTapped(_:)), for: .touchUpInside)

        contentView.addSubview(avatarImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(moreButton)

        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: 30),
            avatarImageView.widthAnchor.constraint(equalTo: avatarImageView.heightAnchor),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: avatarImageView.bottomAnchor, constant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.trailingAnchor.constraint(equalTo: moreButton.trailingAnchor, constant: 5)
        ])
    }
    
}
