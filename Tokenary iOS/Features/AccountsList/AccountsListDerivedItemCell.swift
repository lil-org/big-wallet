// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

protocol AccountsListDerivedItemEventsRespondable: AnyObject {
    func didTapExport(wallet: TokenaryWallet)
    func didTapRemoveAccountIn(wallet: TokenaryWallet, account: ChainType)
}

class AccountsListDerivedItemCell: UICollectionViewCell {
    private lazy var accountIconImage = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    fileprivate lazy var buttonProxy = CustomButton().then {
        $0.addTarget(self, action: #selector(test), for: .touchUpInside)
        $0.isUserInteractionEnabled = true
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.showsMenuAsPrimaryAction = true
    }
    
    private lazy var textContentStackView = UIStackView().then {
        $0.isUserInteractionEnabled = false
        $0.axis = .vertical
        $0.spacing = 2
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
        $0.textColor = UIColor(light: .black, dark: .white)
        $0.font = .systemFont(ofSize: 14, weight: .regular)
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.textAlignment = .center
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    private lazy var tokenTickerLabel = UILabel().then {
        $0.textColor = .gray
        $0.textAlignment = .left
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var addressLabel = UILabel().then {
        $0.textColor = UIColor(light: .black, dark: .white)
        $0.font = .systemFont(ofSize: 14, weight: .regular)
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.textAlignment = .center
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    // MARK: - Private Properties
    
    weak var attachedWallet: TokenaryWallet?
    
    private lazy var responder = Weak(firstResponder(of: AccountsListDerivedItemEventsRespondable.self))
    
    // MARK: - UITableViewCell
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Private Methods

    private func commonInit() {
        setupStyle()
        addSubviews()
        makeConstraints()
    }
    
    private func setupStyle() {
        buttonProxy.layer.borderWidth = CGFloat.pixel
        buttonProxy.layer.cornerRadius = 6
        buttonProxy.layer.borderColor = UIColor(light: .black, dark: .white).cgColor
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        buttonProxy.layer.borderColor = UIColor(light: .black, dark: .white).cgColor
    }
    
    let pressedDownTransform = CGAffineTransform.identity.scaledBy(x: 0.95, y: 0.95)
    private func animate(_ cell: UICollectionViewCell, to transform: CGAffineTransform) {
        UIView.animate(withDuration: 0.4,
                        delay: 0,
                        usingSpringWithDamping: 0.4,
                        initialSpringVelocity: 3,
                        options: [.curveEaseInOut],
                        animations: {
                        cell.transform = transform
            }, completion: nil)
    }
    
    private func addSubviews() {
        contentView.add(insets: .zero) {
            buttonProxy.add {
                accountIconImage
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
            accountIconImage.leadingAnchor.constraint(equalTo: buttonProxy.leadingAnchor, constant: 6)
            accountIconImage.topAnchor.constraint(equalTo: buttonProxy.topAnchor, constant: 4)
            accountIconImage.bottomAnchor.constraint(equalTo: buttonProxy.bottomAnchor, constant: -4)
            textContentStackView.leadingAnchor.constraint(equalTo: accountIconImage.trailingAnchor, constant: 4)
            textContentStackView.topAnchor.constraint(equalTo: accountIconImage.topAnchor)
            textContentStackView.bottomAnchor.constraint(equalTo: accountIconImage.bottomAnchor)
            textContentStackView.trailingAnchor.constraint(equalTo: buttonProxy.trailingAnchor, constant: -6)
            
            accountIconImage.widthAnchor.constraint(equalToConstant: 30)
            accountIconImage.heightAnchor.constraint(equalToConstant: 30)
        }
        textLayoutWidthConstraint = textContentStackView.widthAnchor.constraint(equalToConstant: 130)
    }
    
    private var textLayoutWidthConstraint: NSLayoutConstraint?
    private var viewModel: ViewModel! {
        didSet {
            if UIDevice.isPad {
            DispatchQueue.main.async {
                self.buttonProxy.menu = UIMenu(
                    title: self.viewModel.address,
                    children: [
                        UIDeferredMenuElement.uncached { [self] completion in
                        let copyAddressAction = UIAction(title: Strings.copyAddress) { _ in
                            if let attachedWallet = self.attachedWallet {
                                PasteboardHelper.setPlainNotNil(attachedWallet[viewModel.chainType, .address] ?? nil)
                            }
                        }
                        let showInChainScannerAction = UIAction(title: viewModel.chainType.transactionScaner) { _ in
                            if let address = self.attachedWallet?[viewModel.chainType, .address] ?? nil {
                                LinkHelper.open(viewModel.chainType.scanURL(address))
                            }
                        }
                        let showKeyAction = UIAction(title: Strings.showWalletKey) { _ in
                            if let attachedWallet = self.attachedWallet {
                                self.responder.object?.didTapExport(wallet: attachedWallet)
                            }
                        }
                        let removeAccountAction = UIAction(title: "Remove account", attributes: .destructive) { _ in
                            if let attachedWallet = self.attachedWallet {
                                self.responder.object?.didTapRemoveAccountIn(wallet: attachedWallet, account: viewModel.chainType)
                            }
                            
                        }
                        var itemMenuChildren: [UIMenuElement] = [copyAddressAction, showInChainScannerAction, showKeyAction]
                        if let attachedWallet = self.attachedWallet, attachedWallet.associatedMetadata.allChains.count > 1 {
                            itemMenuChildren.append(removeAccountAction)
                        }
                            completion([
                                UIMenu(
                                    title: "\(viewModel.chainType.title) actions",
                                    options: .displayInline,
                                    children: itemMenuChildren
                                )
                            ])
                        }
                        ]
                    )
            }
            }
            
        }
    }
}

extension AccountsListDerivedItemCell: Configurable {
    struct ViewModel {
        var accountIcon: UIImage
        var address: String
        var chainType: ChainType
        var iconShadowColor: UIColor
    
        var title: String { chainType.title }
        var ticker: String { chainType.ticker }
    }
    
    func configure(with viewModel: ViewModel) {
        accountIconImage.image = viewModel.accountIcon
//        accountIconImage.layer.applySimpleShadow(
//            with: .init(color: viewModel.iconShadowColor, opacity: 0.1, offset: CGPoint(x: 1, y: 1), radius: 4)
//        )
        accountIconImage.layer.applyShadow(
            for: UIBezierPath(roundedRect: accountIconImage.frame, cornerRadius: 8),
            having: .init(color: .green, opacity: 1, offset: CGPoint(x: 1, y: 1), radius: 4)
        )
        tokenTitleLabel.text = viewModel.title
        tokenTickerLabel.text = "(\(viewModel.ticker))"
        addressLabel.text = viewModel.address
        
        if viewModel.chainType == .ethereum {
            textLayoutWidthConstraint?.constant = 110 + 30 + 6
        } else {
            textLayoutWidthConstraint?.constant = 100 + 30 + 6
        }
        textLayoutWidthConstraint?.isActive = true
        setNeedsUpdateConstraints()
        self.viewModel = viewModel
    }
    
    @objc private func test() {
        // attachedWallet, chainType
        let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { _ in
            if let attachedWallet = self.attachedWallet {
                PasteboardHelper.setPlainNotNil(attachedWallet[self.viewModel.chainType, .address] ?? nil)
            }
        }
        let showInChainScannerAction = UIAlertAction(title: viewModel.chainType.transactionScaner, style: .default) { _ in
            if let address = self.attachedWallet?[self.viewModel.chainType, .address] ?? nil {
                LinkHelper.open(self.viewModel.chainType.scanURL(address))
            }
        }
        let showKeyAction = UIAlertAction(title: Strings.showWalletKey, style: .default) { _ in
            if let attachedWallet = self.attachedWallet {
                self.responder.object?.didTapExport(wallet: attachedWallet)
            }
        }
        let removeAccountAction = UIAlertAction(title: "Remove account", style: .default) { _ in
            if let attachedWallet = self.attachedWallet {
                self.responder.object?.didTapRemoveAccountIn(wallet: attachedWallet, account: self.viewModel.chainType)
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        let alertVC = UIAlertController(
            title: "\(self.viewModel.chainType.title) actions", message: nil, preferredStyle: .actionSheet
        ).then {
            $0.addAction(copyAddressAction)
            $0.addAction(showInChainScannerAction)
            $0.addAction(showKeyAction)
            if let attachedWallet = self.attachedWallet, attachedWallet.associatedMetadata.allChains.count > 1 {
                $0.addAction(removeAccountAction)
            }
            $0.addAction(cancelAction)
        }
        self.parentViewController?.present(alertVC, animated: true, completion: nil)
    }
    
    private func configureMenu(with viewModel: ViewModel) {
        
    }
}

class CustomButton: UIButton {
    override var isHighlighted: Bool {
        didSet {
            self.animateScale(isHighlighted: self.isHighlighted, scale: 0.95, animationDuration: 0.1)
        }
    }
}
