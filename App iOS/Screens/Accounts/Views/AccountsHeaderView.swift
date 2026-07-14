// ∅ 2026 lil org

import UIKit

protocol AccountsHeaderViewDelegate: AnyObject {
    func didTapEditButton(_ sender: AccountsHeaderView, sectionIndex: Int)
}

class AccountsHeaderView: UITableViewHeaderFooterView {

    let invisibleButton = UIButton(type: .system)
    let titleLabel = UILabel()
    let editSectionButton = UIButton(type: .system)
    private weak var cellDelegate: AccountsHeaderViewDelegate?
    private var sectionIndex = 0

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func set(title: String, showsButton: Bool, sectionIndex: Int, delegate: AccountsHeaderViewDelegate) {
        titleLabel.text = title.uppercased()
        editSectionButton.isHidden = !showsButton
        invisibleButton.isHidden = !showsButton
        cellDelegate = delegate
        self.sectionIndex = sectionIndex
    }
    
    @IBAction func editSectionButtonTapped(_ sender: Any) {
        cellDelegate?.didTapEditButton(self, sectionIndex: sectionIndex)
    }

    private func configureView() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isOpaque = false
        titleLabel.text = "label"
        titleLabel.contentMode = .left
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5
        titleLabel.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        titleLabel.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)

        var editButtonConfiguration = UIButton.Configuration.plain()
        editButtonConfiguration.title = ""
        editButtonConfiguration.image = UIImage(systemName: "ellipsis.rectangle")
        editButtonConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: .systemFont(ofSize: 13))
        editSectionButton.configuration = editButtonConfiguration
        editSectionButton.translatesAutoresizingMaskIntoConstraints = false

        var invisibleButtonConfiguration = UIButton.Configuration.plain()
        invisibleButtonConfiguration.title = ""
        invisibleButton.configuration = invisibleButtonConfiguration
        invisibleButton.translatesAutoresizingMaskIntoConstraints = false
        invisibleButton.addTarget(nil, action: #selector(editSectionButtonTapped(_:)), for: .touchUpInside)

        addSubview(titleLabel)
        addSubview(editSectionButton)
        addSubview(invisibleButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            safeAreaLayoutGuide.trailingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),

            editSectionButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            editSectionButton.widthAnchor.constraint(equalToConstant: 32),
            editSectionButton.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            invisibleButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            invisibleButton.trailingAnchor.constraint(equalTo: editSectionButton.trailingAnchor, constant: 20),
            invisibleButton.heightAnchor.constraint(equalToConstant: 40),
            safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: invisibleButton.bottomAnchor)
        ])
    }
    
}
