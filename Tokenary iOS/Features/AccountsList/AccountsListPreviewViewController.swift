// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit

class AccountsListPreviewViewController: UIViewController {
    private lazy var dimmedBorderedContentHolderStack = UIStackView().then {
        $0.axis = .vertical
        $0.alignment = .center
        $0.spacing = 8
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.backgroundColor = .secondarySystemBackground
    }
    
    private lazy var tokenaryTitleViewHolder = UIView().then {
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var tokenaryLogoImage = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.image = UIImage(named: "LaunchLogo")
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var tokenaryTitleLabel = UILabel().then {
        $0.textColor = UIColor.tokenary
        $0.text = "Tokenary"
        $0.font = .systemFont(ofSize: 18, weight: .bold)
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.textAlignment = .left
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    
    private lazy var chainIconImage = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.translatesAutoresizingMaskIntoConstraints = false
    }

    init(chainType: ChainType) {
        super.init(nibName: nil, bundle: nil)
        chainIconImage.image = UIImage(named: chainType.iconName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        commonInit()
    }

    // MARK: - Private Methods

    private func commonInit() {
        setupStyle()
        addSubviews()
        makeConstraints()
    }
    
    private func setupStyle() {
        view.backgroundColor = .secondarySystemBackground
    }
    
    private func addSubviews() {
        view.add(insets: .init(all: 10)) {
            dimmedBorderedContentHolderStack.add {
                tokenaryTitleViewHolder.add {
                    tokenaryLogoImage
                    tokenaryTitleLabel
                }
                chainIconImage
            }
        }
    }
    
    private func makeConstraints() {
        NSLayoutConstraint.activate {
            tokenaryLogoImage.topAnchor.constraint(equalTo: tokenaryTitleViewHolder.topAnchor)
            tokenaryLogoImage.bottomAnchor.constraint(equalTo: tokenaryTitleViewHolder.bottomAnchor)
            tokenaryLogoImage.leadingAnchor.constraint(equalTo: tokenaryTitleViewHolder.leadingAnchor)
            tokenaryLogoImage.trailingAnchor.constraint(equalTo: tokenaryTitleLabel.leadingAnchor, constant: -10)
            tokenaryLogoImage.centerYAnchor.constraint(equalTo: tokenaryTitleLabel.centerYAnchor)
            tokenaryTitleLabel.trailingAnchor.constraint(equalTo: tokenaryTitleViewHolder.trailingAnchor)
            
            tokenaryLogoImage.widthAnchor.constraint(equalToConstant: 30).then {
                $0.priority = .required
            }
            tokenaryLogoImage.heightAnchor.constraint(equalToConstant: 30).then {
                $0.priority = .required
            }

            chainIconImage.widthAnchor.constraint(equalToConstant: 80).then {
                $0.priority = .required
            }
            chainIconImage.heightAnchor.constraint(equalToConstant: 80).then {
                $0.priority = .required
            }
        }

        var contentSize = dimmedBorderedContentHolderStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        contentSize += 20.0
        
        preferredContentSize = contentSize
    }
}
