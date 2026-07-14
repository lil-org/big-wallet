// ∅ 2026 lil org

import UIKit

class MultilineLabelTableViewCell: UITableViewCell {

    let multilineLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isOpaque = false
        label.contentMode = .left
        label.text = "label"
        label.font = .systemFont(ofSize: 17)
        label.textAlignment = .left
        label.lineBreakMode = .byCharWrapping
        label.numberOfLines = 0
        label.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        label.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
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
    
    func setup(text: String, largeFont: Bool, oneLine: Bool, pro: Bool) {
        multilineLabel.text = text
        
        if pro {
            multilineLabel.textColor = .secondaryLabel
            multilineLabel.font = UIFont.italicSystemFont(ofSize: 17)
        } else {
            multilineLabel.textColor = .label
            multilineLabel.font = largeFont ? UIFont.systemFont(ofSize: 21, weight: .medium) : UIFont.systemFont(ofSize: 17, weight: .regular)
        }
        
        multilineLabel.numberOfLines = oneLine ? 1 : 0
        multilineLabel.lineBreakMode = oneLine ? .byTruncatingTail : .byCharWrapping
    }

    private func setupViewHierarchy() {
        contentView.isOpaque = false
        contentView.clipsToBounds = true
        contentView.isMultipleTouchEnabled = true
        contentView.contentMode = .center
        separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)

        contentView.addSubview(multilineLabel)

        NSLayoutConstraint.activate([
            multilineLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            multilineLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: multilineLabel.bottomAnchor, constant: 12),
            contentView.trailingAnchor.constraint(greaterThanOrEqualTo: multilineLabel.trailingAnchor, constant: 12)
        ])
    }
    
}
