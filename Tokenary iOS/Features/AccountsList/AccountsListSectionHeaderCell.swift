// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

protocol AccountsListSectionHeaderEventsRespondable: AnyObject {
    func didTapRemove(wallet: TokenaryWallet)
    func didTapExport(wallet: TokenaryWallet)
    func didTapRename(wallet: TokenaryWallet)
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet)
}

class AccountsListSectionHeaderCell: UITableViewHeaderFooterView {
    // MARK: - Subview Properties
    
    private lazy var mainContainerView = UIView().then {
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var accountIconImage = AccountsListImageView().then {
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFit
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var accountNameLabel = UILabel().then {
        $0.font = .systemFont(ofSize: 15, weight: .semibold)
        $0.textColor = .label
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
    }
    
    private lazy var moreButton = ExtendedHitAreaButton().then {
        $0.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    
    // MARK: - Private Properties
    
    weak var attachedWallet: TokenaryWallet?
    
    private lazy var responder = Weak(firstResponder(of: AccountsListSectionHeaderEventsRespondable.self))
    
    // MARK: - UITableViewCell
    
    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        accountIconImage.prepareForReuse()
    }

    // MARK: - Private Methods

    private func commonInit() {
        addSubviews()
        makeConstraints()
    }
    
    private func addSubviews() {
        contentView.add(insets: .zero) {
            mainContainerView.add {
                accountIconImage
                accountNameLabel
                moreButton
            }
        }
    }
    
    private func makeConstraints() {
        NSLayoutConstraint.activate {
            accountIconImage.topAnchor.constraint(equalTo: mainContainerView.topAnchor, constant: 5)
            accountIconImage.bottomAnchor.constraint(equalTo: mainContainerView.bottomAnchor, constant: -5)
            accountIconImage.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor, constant: 16)
            
            accountNameLabel.topAnchor.constraint(equalTo: accountIconImage.topAnchor)
            accountNameLabel.bottomAnchor.constraint(equalTo: accountIconImage.bottomAnchor)
            accountNameLabel.leadingAnchor.constraint(equalTo: accountIconImage.trailingAnchor, constant: 8)
            
            moreButton.centerYAnchor.constraint(equalTo: mainContainerView.centerYAnchor)
            mainContainerView.trailingAnchor.constraint(equalTo: moreButton.trailingAnchor, constant: 20)
            accountNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -10)
            
            accountIconImage.widthAnchor.constraint(equalToConstant: 25)
            accountIconImage.heightAnchor.constraint(equalToConstant: 25)
        }
    }
}

extension AccountsListSectionHeaderCell: Configurable {
    struct ViewModel {
        let id: String
        let accountName: String
        let privateKeyChainType: ChainType?
        let isFilteringAccounts: Bool
        let derivedItemViewModels: [AccountsListDerivedItemCell.ViewModel]
    }
    
    func configure(with viewModel: ViewModel) {
        accountIconImage.configure(with: viewModel.id)
        accountNameLabel.text = viewModel.accountName
        configureMenu(with: viewModel)
    }
    
    func update(name newName: String) {
        accountNameLabel.text = newName
    }
    
    private func configureMenu(with viewModel: ViewModel) {
        if UIDevice.isPad {
            moreButton.showsMenuAsPrimaryAction = true
            moreButton.menu = UIMenu(
                title: self.actionsForWalletDialogTitle,
                children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        guard let self = self else { completion([]); return }
                        
                        var moreMenuChildren: [UIMenuElement] = []
                        let renameAction = UIAction(title: "Rename Wallet") { _ in
                            if let attachedWallet = self.attachedWallet {
                                self.responder.object?.didTapRename(wallet: attachedWallet)
                            }
                        }
                        moreMenuChildren.append(renameAction)
                        if let attachedWallet = self.attachedWallet, attachedWallet.isMnemonic {
                            if !viewModel.isFilteringAccounts {
                                let configureAction = UIAction(title: "Configure accounts") { _ in
                                    if let attachedWallet = self.attachedWallet {
                                        self.responder.object?.didTapReconfigureAccountsIn(wallet: attachedWallet)
                                    }
                                }
                                moreMenuChildren.append(configureAction)
                            }
                        } else {
                            if let privateKeyChainType = viewModel.privateKeyChainType {
                                let copyAddressAction = UIAction(title: Strings.copyAddress) { _ in
                                    if let attachedWallet = self.attachedWallet {
                                        PasteboardHelper.setPlainNotNil(attachedWallet[.address] ?? nil)
                                    }
                                }
                                    
                                let transactionScannerAction = UIAction(title: privateKeyChainType.transactionScaner) { _ in
                                    if let address = self.attachedWallet?[.address] ?? nil {
                                        LinkHelper.open(privateKeyChainType.scanURL(address))
                                    }
                                }
                                moreMenuChildren.append(contentsOf: [copyAddressAction, transactionScannerAction])
                            }
                        }
                        let showWalletKeyAction = UIAction(title: Strings.showWalletKey) { _ in
                            if let attachedWallet = self.attachedWallet {
                                self.responder.object?.didTapExport(wallet: attachedWallet)
                            }
                        }
                        let removeWalletAction = UIAction(title: Strings.removeWallet, attributes: .destructive) { _ in
                            if let attachedWallet = self.attachedWallet {
                                self.responder.object?.didTapRemove(wallet: attachedWallet)
                            }
                        }
                        if viewModel.isFilteringAccounts {
                            moreMenuChildren.append(showWalletKeyAction)
                        } else {
                            moreMenuChildren.append(contentsOf: [showWalletKeyAction, removeWalletAction])
                        }
                        completion([
                            UIMenu(
                                title: self.actionsForWalletDialogTitle,
                                options: .displayInline,
                                children: moreMenuChildren
                            )
                        ])
                    }
                ]
            )
        } else {
            moreButton.addAction(for: .touchUpInside) { _ in
                let renameAction = UIAlertAction(title: "Rename Wallet", style: .default) { _ in
                    if let attachedWallet = self.attachedWallet {
                        self.responder.object?.didTapRename(wallet: attachedWallet)
                    }
                }
                let configureAction = UIAlertAction(title: "Configure accounts", style: .default) { _ in
                    if let attachedWallet = self.attachedWallet {
                        self.responder.object?.didTapReconfigureAccountsIn(wallet: attachedWallet)
                    }
                }
                let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { _ in
                    if let attachedWallet = self.attachedWallet {
                        PasteboardHelper.setPlainNotNil(attachedWallet[.address] ?? nil)
                    }
                }
                let transactionScannerAction = UIAlertAction(title: viewModel.privateKeyChainType?.transactionScaner ?? .empty, style: .default) { _ in
                    if let address = self.attachedWallet?[.address] ?? nil {
                        LinkHelper.open(viewModel.privateKeyChainType?.scanURL(address))
                    }
                }
                let showWalletKeyAction = UIAlertAction(title: Strings.showWalletKey, style: .default) { _ in
                    if let attachedWallet = self.attachedWallet {
                        self.responder.object?.didTapExport(wallet: attachedWallet)
                    }
                }
                let removeWalletAction = UIAlertAction(title: Strings.removeWallet, style: .destructive) { _ in
                    if let attachedWallet = self.attachedWallet {
                        self.responder.object?.didTapRemove(wallet: attachedWallet)
                    }
                }
                let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
                let alertVC = UIAlertController(
                    title: self.actionsForWalletDialogTitle, message: nil, preferredStyle: .actionSheet
                ).then {
                    $0.addAction(renameAction)
                    if let attachedWallet = self.attachedWallet, attachedWallet.isMnemonic {
                        if !viewModel.isFilteringAccounts {
                            $0.addAction(configureAction)
                        }
                    } else {
                        $0.addAction(copyAddressAction)
                        $0.addAction(transactionScannerAction)
                    }
                    $0.addAction(showWalletKeyAction)
                    if !viewModel.isFilteringAccounts {
                        $0.addAction(removeWalletAction)
                    }
                    $0.addAction(cancelAction)
                }
                self.parentViewController?.present(alertVC, animated: true, completion: nil)
            }
        }
    }
    
    private var actionsForWalletDialogTitle: String {
        if let address = attachedWallet?[.address] ?? nil {
            return address
        } else {
            return "Mnemonic wallet"
        }
    }
}
