// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit
import BlockiesSwift

class AccountsListPresenter: NSObject, AccountsListInput {
    
    // MARK: - Public Properties
    
    var mode: AccountsListMode
    weak var view: AccountsListOutput?
    
    // MARK: - Private Properties
    
    private var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    private var chain = EthereumChain.ethereum
    private let walletsManager: WalletsManager
    
    private var accounts: [AccountsListSectionHeaderCell.ViewModel] = []
    
    private var filteredWallets: [TokenaryWallet] {
        let wallets = WalletsManager.shared.wallets.get()
        if
            case let .choseAccount(forChain: selectedChain) = mode,
            let selectedChain = selectedChain
        {
            return wallets.filter { $0.associatedMetadata.allChains.contains(selectedChain) }
        } else {
            return wallets
        }
    }
    
    // MARK: - UIViewController
    
    init(
        walletsManager: WalletsManager,
        onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?,
        mode: AccountsListMode
    ) {
        self.walletsManager = walletsManager
        self.onSelectedWallet = onSelectedWallet
        self.mode = mode
        super.init()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(processInput),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadData(notification:)),
            name: Notification.Name.walletsChanged,
            object: nil
        )
    }
    
    func viewDidLoad() {
        // Be sure to call here (Keychain bug #)
        //  Or maybe there is problem with permissions
        if walletsManager.wallets.isEmpty {
            walletsManager.start()
        }
        
        updateDataState()
    }
    
    func viewWillAppear() {
        reloadData()
    }
    
    // MARK: - Private Methods
    
    @objc private func processInput() {
        guard
            let url = launchURL?.absoluteString, url.hasPrefix(Constants.tokenarySchemePrefix),
            let request = SafariRequest(query: String(url.dropFirst(Constants.tokenarySchemePrefix.count)))
        else { return }

        launchURL = nil

        let action = DappRequestProcessor.processSafariRequest(request) { [weak self] in
            self?.view?.openSafari(requestId: request.id)
        }
        
        switch action {
        case .none, .justShowApp:
            break
        case .selectAccount(let action):
            let accountsListVC = AccountsListAssembly.build(
                for: .choseAccount(forChain: ChainType(provider: action.provider)),
                onSelectedWallet: action.completion
            ).then {
                $0.isModalInPresentation = true
            }
            view?.presentForSafariRequest(accountsListVC, id: request.id)
        case .approveMessage(let action):
            let approveViewController = ApproveViewController.with(subject: action.subject,
                                                                   address: action.address,
                                                                   meta: action.meta,
                                                                   peerMeta: action.peerMeta,
                                                                   completion: action.completion)
            view?.presentForSafariRequest(approveViewController.inNavigationController, id: request.id)
        case .approveTransaction(let action):
            let approveTransactionViewController = ApproveTransactionViewController.with(transaction: action.transaction,
                                                                                         chain: action.chain,
                                                                                         address: action.address,
                                                                                         peerMeta: action.peerMeta,
                                                                                         completion: action.completion)
            view?.presentForSafariRequest(approveTransactionViewController.inNavigationController, id: request.id)
        }
    }
    
    @objc private func reloadData(notification: NSNotification? = nil) {
        if let walletsChangeSet = notification?.userInfo?["changeset"] as? WalletsManager.TokenaryWalletChangeSet {
            self.updateAccounts(with: walletsChangeSet)
        } else {
            self.updateAccounts(
                with: .init(toAdd: self.walletsManager.wallets.get(), toUpdate: [], toRemove: [])
            )
        }
        self.updateDataState()
    }
    
    private func updateDataState() {
        let isEmpty = filteredWallets.isEmpty
        view?.dataState = isEmpty ? .noData : .hasData
        let canScroll = !isEmpty
        if view?.tableView.isScrollEnabled != canScroll {
            view?.tableView.isScrollEnabled = canScroll
        }
    }
    
    func updateAccounts(with walletsChangeSet: WalletsManager.TokenaryWalletChangeSet) {
        DispatchQueue.global().async {
            var filteredWalletsChangeSet = walletsChangeSet
            filteredWalletsChangeSet.applyFilter { wallets in
                if
                    case let .choseAccount(forChain: selectedChain) = self.mode,
                    let selectedChain = selectedChain
                {
                    return wallets.filter { $0.associatedMetadata.allChains.contains(selectedChain) }
                } else {
                    return wallets
                }
            }
            var updatedDeletedIds: [String] = []
            // This is special case, when we update filtered model, in such way it should not be displayed anymore
            if filteredWalletsChangeSet.toUpdate != walletsChangeSet.toUpdate {
                updatedDeletedIds = Set(walletsChangeSet.toUpdate)
                    .subtracting(filteredWalletsChangeSet.toUpdate)
                    .map(\.id)
            }
            
            let vmToAdd: [AccountsListSectionHeaderCell.ViewModel] = filteredWalletsChangeSet.toAdd.map(self.transform)
            let indicesToRemove: IndexSet = IndexSet(
                self.accounts
                    .enumerated()
                    .filter { accountEnumeration in
                        filteredWalletsChangeSet.toRemove.contains(where: { $0.id == accountEnumeration.element.id }) ||
                        updatedDeletedIds.contains(accountEnumeration.element.id)
                    }
                    .map { $0.offset }
            )
            let updateVM: [(Int, AccountsListSectionHeaderCell.ViewModel)] = filteredWalletsChangeSet.toUpdate.compactMap { updateWallet in
                guard let updateIdx = self.accounts.firstIndex(where: { $0.id == updateWallet.id }) else { return nil }
                let updateVM: AccountsListSectionHeaderCell.ViewModel = self.transform(updateWallet)
                return (updateIdx, updateVM)
            }
            
            DispatchQueue.main.async {
                for (updateIdx, accountVM) in updateVM {
                    self.accounts[updateIdx] = accountVM
                }
                self.accounts.remove(atOffsets: indicesToRemove)
                self.accounts.append(contentsOf: vmToAdd)
//                if vmToAdd.count == 1 && updateVM.count == .zero && indicesToRemove.count == .zero {
//                    self.scrollToWalletAndBlink(walletId: vmToAdd.first!.id)
//                }
//                if updateVM.count == 1 {
//                    UIView.setAnimationsEnabled(false)
//                    self.view?.tableView.beginUpdates()
//                    let cell = self.view?.tableView.cellForRow(at: IndexPath(item: updateVM.first!.0, section: .zero)) as? AccountsListItemCell
//                    cell?.update(collection: updateVM.first!.1.derivedItemViewModels)
//                    cell?.update(name: updateVM.first!.1.accountName)
////                    cell?.layoutSubviews()
//                    self.view?.tableView.endUpdates()
//                    UIView.setAnimationsEnabled(true)
////                    self.view?.tableView.reloadRows(at: [IndexPath(item: updateVM.first!.0, section: .zero)], with: .none)
////                    self.view?.tableView.reconfigureRows(at: <#T##[IndexPath]#>)
//
//                }
//                if indicesToRemove.count != .zero {
////                    self.view?.tableView.beginUpdates()
//                    let indexPaths = indicesToRemove.map { IndexPath(item: $0, section: .zero) }
//                    self.view?.tableView.deleteRows(at: indexPaths, with: .none)
////                    self.view?.tableView.endUpdates()
//                }
//
//                if vmToAdd.count == 1 {
////                    self.view?.tableView.beginUpdates()
//                    self.view?.tableView.insertRows(
//                        at: [IndexPath(row: self.accounts.count - 1, section: .zero)], with: .fade
//                    )
////                    self.view?.tableView.endUpdates()
//                }
//                if vmToAdd.count > 1 {
                    self.view?.tableView.reloadData()
//                }
            }
        }
    }
    
    private func scrollToWalletAndBlink(walletId: String) {
        self.view?.tableView.reloadData()
    }

    private func transform(_ wallet: TokenaryWallet) -> AccountsListSectionHeaderCell.ViewModel {
        let icon: UIImage
        let privateKeyChainType = wallet.associatedMetadata.privateKeyChain
        
        if wallet.isMnemonic {
            if wallet.associatedMetadata.allChains.contains(.ethereum) {
                icon = Blockies(
                    seed: wallet[.ethereum, .address]??.lowercased(), size: 10
                ).createImage() ?? UIImage(named: "multiChainGrid")!
            } else {
                icon = UIImage(named: "multiChainGrid")!
            }
        } else {
            if privateKeyChainType! == .ethereum {
                icon = Blockies(
                    seed: wallet[.address]??.lowercased(), size: 10
                ).createImage() ?? UIImage(named: "multiChainGrid")!
            } else {
                icon = UIImage(named: privateKeyChainType!.iconName)!
            }
        }
//        transform(wallet).sorted(by: { $0.title > $1.title })
        return AccountsListSectionHeaderCell.ViewModel(
            id: wallet.id,
            icon: icon,
            accountName: wallet.name,
            privateKeyChainType: wallet.isMnemonic ? nil : privateKeyChainType!,
            isFilteringAccounts: mode.isFilteringAccounts,
            derivedItemViewModels: transform(wallet).sorted(by: { $0.title > $1.title })
        )
    }
    
    private func transform(_ wallet: TokenaryWallet) -> [AccountsListDerivedItemCell.ViewModel] {
        guard wallet.isMnemonic else { return [] }
        if
            case let .choseAccount(forChain: selectedChain) = mode,
            let selectedChain = selectedChain
        {
            if wallet.associatedMetadata.allChains.contains(selectedChain) {
                return [transform(wallet, chain: selectedChain)]
            } else {
                assertionFailure("This should not normally happen!")
                return []
            }
        } else {
            return wallet.associatedMetadata.allChains.map {
                transform(wallet, chain: $0)
            }
        }
    }
    
    private func transform(_ wallet: TokenaryWallet, chain: ChainType) -> AccountsListDerivedItemCell.ViewModel {
        let address = wallet[chain, .address] ?? .empty
        return AccountsListDerivedItemCell.ViewModel(
            accountIcon: UIImage(named: chain.iconName)!,
            address: address ?? .empty,
            chainType: chain,
            isFilteringAccounts: mode.isFilteringAccounts
        )
    }
}

// MARK: - AccountsListPresenter + AccountsListInput

extension AccountsListPresenter {
    
    func createNewAccountAndShowSecretWordsFor(chains: [ChainType]) {
        guard
            let wallet = try? walletsManager.createMnemonicWallet(
                chainTypes: chains
            )
        else { return }
        view?.showKey(wallet: wallet, mnemonic: true)
    }
    
    // ToDo: There is one special case here - when we come to change/request accounts with an empty provider -> this way we should have shown both both all-chains and their sub-chain info, however for now, we just drop side-chain choosing and will implement this functionality later
    func didSelect(chain: EthereumChain) {
        self.chain = chain
    }
    
    func cancelButtonWasTapped() {
        onSelectedWallet?(nil, nil)
    }
    
    func didSelect(wallet: TokenaryWallet) {
        onSelectedWallet?(chain, wallet)
    }
}

// MARK: - AccountsListPresenter + UITableViewDelegate

extension AccountsListPresenter {
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { true }
    
    func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath
    ) {
        if editingStyle == .delete, let walletToRemove = filteredWallets[safe: indexPath.row] {
            view?.didTapRemove(wallet: walletToRemove)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if mode != .mainScreen, let selectedWallet = filteredWallets[safe: indexPath.row] {
            didSelect(wallet: selectedWallet)
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        46
    }
    
//    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
//
//        // Top corners
//        let maskPathTop = UIBezierPath(roundedRect: cell.contentView.bounds, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 10.0, height: 10.0))
//        let shapeLayerTop = CAShapeLayer()
//        shapeLayerTop.frame = cell.contentView.bounds
//        shapeLayerTop.path = maskPathTop.cgPath
//
//        //Bottom corners
//        let maskPathBottom = UIBezierPath(roundedRect: cell.contentView.bounds, byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 5.0, height: 5.0))
//        let shapeLayerBottom = CAShapeLayer()
//        shapeLayerBottom.frame = cell.contentView.bounds
//        shapeLayerBottom.path = maskPathBottom.cgPath
//
//        // All corners
//        let maskPathAll = UIBezierPath(roundedRect: cell.contentView.bounds, byRoundingCorners: [.topLeft, .topRight, .bottomRight, .bottomLeft], cornerRadii: CGSize(width: 5.0, height: 5.0))
//        let shapeLayerAll = CAShapeLayer()
//        shapeLayerAll.frame = cell.contentView.bounds
//        shapeLayerAll.path = maskPathAll.cgPath
//
//        if indexPath.row == 0 && indexPath.row == tableView.numberOfRows(inSection: indexPath.section) - 1 {
//            cell.contentView.layer.mask = shapeLayerAll
//        } else if indexPath.row == 0 {
//            cell.contentView.layer.mask = shapeLayerTop
//        } else if indexPath.row == tableView.numberOfRows(inSection: indexPath.section) - 1 {
//            cell.contentView.layer.mask = shapeLayerBottom
//        }
//    }
    
    struct AccountsListContextMenuIdentifier: Codable {
        let accountIdentifier: String
        let chainType: ChainType
        let rowIndex: Int
        
        init(accountIdentifier: String, chainType: ChainType, rowIndex: Int) {
            self.accountIdentifier = accountIdentifier
            self.chainType = chainType
            self.rowIndex = rowIndex
        }
        
        func copy(with zone: NSZone? = nil) -> Any {
            AccountsListContextMenuIdentifier(
                accountIdentifier: accountIdentifier, chainType: chainType, rowIndex: rowIndex
            )
        }
    }
    
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let identifier = AccountsListContextMenuIdentifier(
            accountIdentifier: accounts[indexPath.section].id,
            chainType: accounts[indexPath.section].derivedItemViewModels[indexPath.row].chainType,
            rowIndex: indexPath.row
        )
        let encoded = try? JSONEncoder().encode(identifier)
        let encodedStr = String(data: encoded!, encoding: .utf8)!
        let accountVM = accounts[indexPath.section].derivedItemViewModels[indexPath.row]
        let attachedWallet: TokenaryWallet? = WalletsManager.shared.getWallet(id: self.accounts[indexPath.section].id)
        return UIContextMenuConfiguration(
            identifier: NSString(string: encodedStr),
            previewProvider: {
                AccountsListPreviewViewController(chainType: accountVM.chainType)
            },
            actionProvider: { _ in
                return UIMenu(
                    title: accountVM.address,
                    children: [
                        UIDeferredMenuElement.uncached { [self] completion in
                            let copyAddressAction = UIAction(title: Strings.copyAddress) { _ in
                                if let attachedWallet = attachedWallet {
                                    PasteboardHelper.setPlainNotNil(attachedWallet[accountVM.chainType, .address] ?? nil)
                                }
                            }
                            let showInChainScannerAction = UIAction(title: accountVM.chainType.transactionScaner) { _ in
                                if let address = attachedWallet?[accountVM.chainType, .address] ?? nil {
                                    LinkHelper.open(accountVM.chainType.scanURL(address))
                                }
                            }
                            let showKeyAction = UIAction(title: Strings.showWalletKey) { _ in
                                if let attachedWallet = attachedWallet {
//                                    self.responder.object?.didTapExport(wallet: attachedWallet)
                                }
                            }
                            let removeAccountAction = UIAction(title: "Remove account", attributes: .destructive) { _ in
                                if let attachedWallet = attachedWallet {
//                                    self.responder.object?.didTapRemoveAccountIn(wallet: attachedWallet, account: accountVM.chainType)
                                }
                                
                            }
                            var itemMenuChildren: [UIMenuElement] = [
                                copyAddressAction, showInChainScannerAction, showKeyAction
                            ]
                            if
                                let attachedWallet = attachedWallet,
                                attachedWallet.associatedMetadata.allChains.count > 1,
                                !accountVM.isFilteringAccounts
                            {
                                itemMenuChildren.append(removeAccountAction)
                            }
                            completion(
                                [
                                    UIMenu(
                                        title: "\(accountVM.chainType.title) actions",
                                        options: .displayInline,
                                        children: itemMenuChildren
                                    )
                                ]
                            )
                        }
                    ]
                )
            }
        )
    }
    
    func tableView(
        _ tableView: UITableView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        animator.addCompletion {
            if let identifier = configuration.identifier as? AccountsListContextMenuIdentifier {
                print("We are printing: \(identifier.accountIdentifier)")
            }
        }
    }
    
    private func makeTargetedPreview(
        for configuration: UIContextMenuConfiguration,
        isHighlighting: Bool
    ) -> UITargetedPreview? {
        guard
            let contextIdentifierJSON = configuration.identifier as? String,
            let contextIdentifierData = contextIdentifierJSON.data(using: .utf8),
            let contextIdentifier = try? JSONDecoder().decode(AccountsListContextMenuIdentifier.self, from: contextIdentifierData),
            let sectionIndex = accounts.firstIndex(where: { $0.id == contextIdentifier.accountIdentifier }),
            let cell = view?.tableView.cellForRow(
                at: IndexPath(row: contextIdentifier.rowIndex, section: sectionIndex)
            ) as? AccountsListDerivedItemCell,
            let snapshot = cell.accountIconBorderView.snapshotView(afterScreenUpdates: false)
        else { return nil }

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        
        let previewTarget = UIPreviewTarget(
            container: cell.accountIconBorderView,
            center: CGPoint(x: cell.accountIconBorderView.bounds.midX, y: cell.accountIconBorderView.bounds.midY)
        )
        return UITargetedPreview(view: snapshot, parameters: parameters, target: previewTarget)
    }
    
    func tableView(
        _ tableView: UITableView,
        previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        makeTargetedPreview(for: configuration, isHighlighting: true)
    }
    
    func tableView(
        _ tableView: UITableView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        makeTargetedPreview(for: configuration, isHighlighting: false)
    }
}

// MARK: - AccountsListPresenter + UITableViewDataSource

extension AccountsListPresenter {
    
    func numberOfSections(in tableView: UITableView) -> Int { accounts.count }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        accounts[section].derivedItemViewModels.count
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let cell = tableView.dequeueReusableHeaderFooterOfType(AccountsListSectionHeaderCell.self)
        DispatchQueue.main.async {
            cell.configure(with: self.accounts[section])
            cell.attachedWallet = WalletsManager.shared.getWallet(id: self.accounts[section].id)
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountsListDerivedItemCell.self, for: indexPath)
        DispatchQueue.main.async {
            cell.configure(with: self.accounts[indexPath.section].derivedItemViewModels[indexPath.row])
            cell.attachedWallet = WalletsManager.shared.getWallet(id: self.accounts[indexPath.section].id)
        }
        return cell
    }
}
