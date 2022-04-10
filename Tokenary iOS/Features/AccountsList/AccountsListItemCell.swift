// Copyright © 2022 Tokenary. All rights reserved.

import UIKit
import BlockiesSwift

protocol AccountsListItemEventsRespondable: AnyObject {
    func didTapRemove(wallet: TokenaryWallet)
    func didTapExport(wallet: TokenaryWallet)
    func didTapRename(wallet: TokenaryWallet)
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet)
}

class AccountsListItemCell: UITableViewCell {
    // MARK: - Subview Properties
    
    private lazy var mainContainerView = UIView().then {
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var accountIconImage = UIImageView().then {
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFit
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var labelHolderStack = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 2
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var accountNameLabel = UILabel().then {
        $0.font = .systemFont(ofSize: 19, weight: .medium)
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
    }
    
    private lazy var privateKeyBasedAccountAddressLabel = UILabel().then {
        $0.font = .systemFont(ofSize: 15, weight: .regular)
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

    private lazy var stackView = UIStackView().then {
        $0.axis = .vertical
        $0.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private lazy var wrappingCollectionLayout = AlignedCollectionViewFlowLayout(
        horizontalAlignment: .leading, verticalAlignment: .top
    ).then {
        $0.sectionInset = .init(horizontal: 10)
        $0.minimumLineSpacing = 6
        $0.minimumInteritemSpacing = 6
        $0.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
    }
    
    private lazy var accountsCollection = TestView(
        frame: .zero, collectionViewLayout: wrappingCollectionLayout
    ).then {
        $0.isScrollEnabled = false
        $0.showsVerticalScrollIndicator = false
        $0.showsHorizontalScrollIndicator = false
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.registerCell(class: AccountsListDerivedItemCell.self)
        $0.backgroundColor = .clear
        $0.dataSource = self
        $0.delegate = self
    }
    
    // MARK: - Private Properties
    
    weak var attachedWallet: TokenaryWallet?
    
    private lazy var responder = Weak(firstResponder(of: AccountsListItemEventsRespondable.self))
    
    // MARK: - UITableViewCell

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
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
        selectionStyle = .default
        backgroundColor = UIColor(light: .white, dark: .black)
    }
    
    private let proxyView = UIView()
    
    private func addSubviews() {
        contentView.add(insets: .zero) {
            stackView.add {
                mainContainerView.add {
                    accountIconImage
                    labelHolderStack.add {
                        accountNameLabel
                        privateKeyBasedAccountAddressLabel
                    }
                    moreButton
                }
                accountsCollection
            }
        }
    }
    
    private func makeConstraints() {
        NSLayoutConstraint.activate {
            accountIconImage.topAnchor.constraint(equalTo: mainContainerView.topAnchor, constant: 5)
            accountIconImage.bottomAnchor.constraint(equalTo: mainContainerView.bottomAnchor, constant: -5)
            accountIconImage.leadingAnchor.constraint(equalTo: mainContainerView.leadingAnchor, constant: 16)
            
            labelHolderStack.topAnchor.constraint(equalTo: accountIconImage.topAnchor)
            labelHolderStack.bottomAnchor.constraint(equalTo: accountIconImage.bottomAnchor)
            labelHolderStack.leadingAnchor.constraint(equalTo: accountIconImage.trailingAnchor, constant: 8)
            
            moreButton.centerYAnchor.constraint(equalTo: mainContainerView.centerYAnchor)
            mainContainerView.trailingAnchor.constraint(equalTo: moreButton.trailingAnchor, constant: 20)
//            labelHolderStack.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -10)
//                .then {
//                $0.priority = .defaultHigh
//            }
            labelHolderStack.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -10)
            
            accountIconImage.widthAnchor.constraint(equalToConstant: 40)
            accountIconImage.heightAnchor.constraint(equalToConstant: 40)
        }
        myCollectionViewHeight = accountsCollection.heightAnchor.constraint(equalToConstant: .zero)
        myCollectionViewHeight?.isActive = true
    }
    
    weak var myCollectionViewHeight: NSLayoutConstraint?
    
    private var items: [AccountsListDerivedItemCell.ViewModel] = [] {
        didSet {
            self.accountsCollection.reloadData()
        }
    }
}

extension AccountsListItemCell: Configurable {
    struct ViewModel {
        let id: String
        let icon: UIImage
        let accountName: String
        let accountAddress: String?
        let chainType: ChainType?
        let isFilteringAccounts: Bool
        let derivedItemViewModels: [AccountsListDerivedItemCell.ViewModel]
    }
    
    func configure(with viewModel: ViewModel) {
        accountIconImage.image = viewModel.icon
        accountNameLabel.text = viewModel.accountName
        if let accountAddress = viewModel.accountAddress {
            privateKeyBasedAccountAddressLabel.isHidden = false
            privateKeyBasedAccountAddressLabel.text = accountAddress
        } else {
            privateKeyBasedAccountAddressLabel.isHidden = true
        }
        mainContainerView.layoutSubviews()
        configureMenu(with: viewModel)
        configureDerivedAccounts(with: viewModel)
    }
    
    private var actionsForWalletDialogTitle: String {
        if let address = attachedWallet?[.address] ?? nil {
            return address
        } else {
            return "Mnemonic wallet"
        }
    }
    
    private func configureMenu(with viewModel: ViewModel) {
        if UIDevice.isPad {
            moreButton.showsMenuAsPrimaryAction = true
            moreButton.menu = UIMenu(
                title: .empty,
                children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        var moreMenuChildren: [UIMenuElement] = []
                        let renameAction = UIAction(title: "Rename Wallet") { _ in
                            if let attachedWallet = self?.attachedWallet {
                                self?.responder.object?.didTapRename(wallet: attachedWallet)
                            }
                        }
                        moreMenuChildren.append(renameAction)
                        if let attachedWallet = self?.attachedWallet, attachedWallet.isMnemonic {
                            if !viewModel.isFilteringAccounts {
                                let configureAction = UIAction(title: "Configure accounts") { _ in
                                    if let attachedWallet = self?.attachedWallet {
                                        self?.responder.object?.didTapReconfigureAccountsIn(wallet: attachedWallet)
                                    }
                                }
                                moreMenuChildren.append(configureAction)
                            }
                        } else {
                            if let chainType = viewModel.chainType {
                                let copyAddressAction = UIAction(title: Strings.copyAddress) { _ in
                                    if let attachedWallet = self?.attachedWallet {
                                        PasteboardHelper.setPlainNotNil(attachedWallet[.address] ?? nil)
                                    }
                                }
                                    
                                let transactionScannerAction = UIAction(title: chainType.transactionScaner) { _ in
                                    if let address = self?.attachedWallet?[.address] ?? nil {
                                        LinkHelper.open(chainType.scanURL(address))
                                    }
                                }
                                moreMenuChildren.append(contentsOf: [copyAddressAction, transactionScannerAction])
                            }
                        }
                        let showWalletKeyAction = UIAction(title: Strings.showWalletKey) { _ in
                            if let attachedWallet = self?.attachedWallet {
                                self?.responder.object?.didTapExport(wallet: attachedWallet)
                            }
                        }
                        let removeWalletAction = UIAction(title: Strings.removeWallet, attributes: .destructive) { _ in
                            if let attachedWallet = self?.attachedWallet {
                                self?.responder.object?.didTapRemove(wallet: attachedWallet)
                            }
                        }
                        if viewModel.isFilteringAccounts {
                            moreMenuChildren.append(showWalletKeyAction)
                        } else {
                            moreMenuChildren.append(contentsOf: [showWalletKeyAction, removeWalletAction])
                        }
                        completion([
                            UIMenu(
                                title: .empty,
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
                let transactionScannerAction = UIAlertAction(title: viewModel.chainType?.transactionScaner ?? .empty, style: .default) { _ in
                    if let address = self.attachedWallet?[.address] ?? nil {
                        LinkHelper.open(viewModel.chainType?.scanURL(address))
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
    
    override func layoutSubviews() {
        super.layoutSubviews()
        print(1234)
    }
    
    private func configureDerivedAccounts(with viewModel: ViewModel) {
        items = viewModel.derivedItemViewModels
//        setNeedsLayout()
        wrappingCollectionLayout.invalidateLayout()
        switch viewModel.derivedItemViewModels.count {
        case 3:
            myCollectionViewHeight?.constant = 38 * 2 + 6 * 2
        case 2, 1:
            myCollectionViewHeight?.constant = 38 + 6
        default:
            myCollectionViewHeight?.constant = .zero
        }

        accountsCollection.setNeedsUpdateConstraints()
    }
    
    func update(name: String) {
        if accountNameLabel.text != name {
            accountNameLabel.text = name
        }
    }
    
    func update(collection elements: [AccountsListDerivedItemCell.ViewModel]) {
        items = elements
//        setNeedsLayout()
        wrappingCollectionLayout.invalidateLayout()
        switch elements.count {
        case 3:
            myCollectionViewHeight?.constant = 38 * 2 + 6 * 2
        case 2, 1:
            myCollectionViewHeight?.constant = 38 + 6
        default:
            myCollectionViewHeight?.constant = .zero
        }

        accountsCollection.setNeedsUpdateConstraints()
    }
}

extension AccountsListItemCell: UICollectionViewDataSource {
    func collectionView(
        _ collectionView: UICollectionView, numberOfItemsInSection section: Int
    ) -> Int { items.count }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let myCell: AccountsListDerivedItemCell = collectionView.dequeueReusableCell(for: indexPath)
        myCell.configure(with: items[indexPath.item])
        myCell.attachedWallet = attachedWallet
        return myCell
    }
}

extension AccountsListItemCell: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        return false // all cell items you do not want to be selectable
    }
}
