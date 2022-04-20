// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

class AccountsListDerivedItemCell: UITableViewCell {
    // MARK: - Subview Properties
    
    private lazy var mainContainerView = UIView().then {
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private(set) lazy var accountIconBorderView = UIView().then {
        $0.layer.cornerRadius = 10
        $0.layer.borderColor = UIColor.gray.cgColor
        $0.layer.borderWidth = 1.0
        $0.layer.masksToBounds = true
        $0.translatesAutoresizingMaskIntoConstraints = false
    }

    private(set) lazy var accountIconImage = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var textContentStackView = UIStackView().then {
        $0.isUserInteractionEnabled = false
        $0.axis = .vertical
        $0.spacing = 2
        $0.alignment = .leading
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentHuggingPriority(.required, for: .vertical)
    }
    
    private lazy var namingLabelsStackView = UIStackView().then {
        $0.isUserInteractionEnabled = false
        $0.axis = .horizontal
        $0.spacing = 4
        $0.distribution = .equalCentering
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentHuggingPriority(.required, for: .horizontal)
    }
    
    private lazy var tokenTitleLabel = UILabel().then {
        $0.textColor = .label
        $0.font = .systemFont(ofSize: 14, weight: .bold)
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    private lazy var tokenTickerLabel = UILabel().then {
        $0.textColor = .gray
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var addressLabel = UILabel().then {
        $0.textColor = .secondaryLabel
        $0.font = .systemFont(ofSize: 14, weight: .regular)
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    // MARK: - Public Properties
    
    var proxySetHighlighted: Bool = true
    
    // MARK: - UITableViewCell

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        proxySetHighlighted = false
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        if proxySetHighlighted {
            if highlighted {
                super.setHighlighted(highlighted, animated: animated)
            }
        } else {
            super.setHighlighted(highlighted, animated: animated)
        }
    }

    // MARK: - Private Methods

    private func commonInit() {
        setupStyle()
        addSubviews()
        makeConstraints()
    }
    
    private func setupStyle() {
        selectionStyle = .default
        backgroundColor = .secondarySystemGroupedBackground
        separatorInset = .init(vertical: .zero, left: 14 + 14 + 30, right: .zero)
    }
    
    private func addSubviews() {
        contentView.add(insets: .zero) {
            mainContainerView.add {
                accountIconBorderView.add(insets: .zero) {
                    accountIconImage
                }
                textContentStackView.add {
                    namingLabelsStackView.add {
                        tokenTitleLabel
                        tokenTickerLabel
                    }
                    addressLabel
                }
            }
        }
    }
    
    private func makeConstraints() {
        NSLayoutConstraint.activate {
            accountIconBorderView.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor, constant: 14)
            accountIconBorderView.topAnchor.constraint(equalTo: mainContainerView.topAnchor, constant: 8)
            accountIconBorderView.bottomAnchor.constraint(equalTo: mainContainerView.bottomAnchor, constant: -8)
            
            textContentStackView.leadingAnchor.constraint(equalTo: accountIconBorderView.trailingAnchor, constant: 14)
            textContentStackView.topAnchor.constraint(equalTo: accountIconBorderView.topAnchor)
            textContentStackView.bottomAnchor.constraint(equalTo: accountIconBorderView.bottomAnchor)
            textContentStackView.trailingAnchor.constraint(equalTo: mainContainerView.trailingAnchor, constant: -6)
            
            accountIconBorderView.widthAnchor.constraint(equalToConstant: 30)
            accountIconBorderView.heightAnchor.constraint(equalToConstant: 30)
        }
    }
}
    
extension AccountsListDerivedItemCell: Configurable {
    struct ViewModel: Equatable {
        let accountIcon: UIImage
        let address: String
        let chainType: ChainType
        let isFilteringAccounts: Bool
    
        var title: String { chainType.title }
        var ticker: String { chainType.ticker }
    }
    
    func configure(with viewModel: ViewModel) {
        accountIconImage.image = viewModel.accountIcon
        
        if viewModel.chainType == .solana {
            accountIconBorderView.layer.cornerRadius = 10
        } else {
            accountIconBorderView.layer.cornerRadius = 15
        }
        
        tokenTitleLabel.text = viewModel.title
        tokenTickerLabel.text = Symbols.leftBrace + viewModel.ticker + Symbols.rightBrace
        addressLabel.text = viewModel.address
    }
}
