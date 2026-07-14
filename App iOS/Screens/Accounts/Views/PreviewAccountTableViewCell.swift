// ∅ 2026 lil org

import UIKit

protocol PreviewAccountTableViewCellDelegate: AnyObject {
    func didToggleSwitch(_ sender: PreviewAccountTableViewCell)
}

class PreviewAccountTableViewCell: UITableViewCell {

    private weak var cellDelegate: PreviewAccountTableViewCellDelegate?

    let coinSwitch = UISwitch()
    let logoImageView = UIImageView()
    let titleLabel = UILabel()
    let indexLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func setup(title: String, image: UIImage?, index: Int, isEnabled: Bool, delegate: PreviewAccountTableViewCellDelegate) {
        cellDelegate = delegate
        logoImageView.image = image
        titleLabel.text = title
        coinSwitch.isOn = isEnabled
        indexLabel.text = String(index)
    }
    
    func toggle() {
        coinSwitch.isOn.toggle()
    }
    
    @IBAction func didToggleSwitch(_ sender: Any) {
        cellDelegate?.didToggleSwitch(self)
    }

    private func configureView() {
        selectionStyle = .default
        separatorInset = UIEdgeInsets(top: 0, left: 76.5, bottom: 0, right: 0)

        contentView.isOpaque = false
        contentView.clipsToBounds = true
        contentView.isMultipleTouchEnabled = true
        contentView.contentMode = .center

        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.isOpaque = false
        indexLabel.text = "0"
        indexLabel.contentMode = .left
        indexLabel.textAlignment = .center
        indexLabel.adjustsFontSizeToFitWidth = true
        indexLabel.minimumScaleFactor = 0.5
        indexLabel.font = .systemFont(ofSize: 12)
        indexLabel.textColor = .tertiaryLabel
        indexLabel.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        indexLabel.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)

        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        logoImageView.clipsToBounds = true
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.layer.cornerRadius = 15
        logoImageView.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        logoImageView.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isOpaque = false
        titleLabel.text = "label"
        titleLabel.contentMode = .left
        titleLabel.font = .systemFont(ofSize: 21, weight: .medium)
        titleLabel.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        titleLabel.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)

        coinSwitch.translatesAutoresizingMaskIntoConstraints = false
        coinSwitch.isOpaque = false
        coinSwitch.isOn = true
        coinSwitch.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        coinSwitch.setContentHuggingPriority(.defaultHigh, for: .vertical)
        coinSwitch.addTarget(self, action: #selector(didToggleSwitch(_:)), for: .valueChanged)

        contentView.addSubview(logoImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(coinSwitch)
        contentView.addSubview(indexLabel)

        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            indexLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 16.5),

            logoImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            logoImageView.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 8),
            logoImageView.widthAnchor.constraint(equalToConstant: 30),
            logoImageView.widthAnchor.constraint(equalTo: logoImageView.heightAnchor),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: logoImageView.bottomAnchor, constant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: logoImageView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            coinSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            coinSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.trailingAnchor.constraint(equalTo: coinSwitch.trailingAnchor, constant: 12)
        ])
    }
    
}
