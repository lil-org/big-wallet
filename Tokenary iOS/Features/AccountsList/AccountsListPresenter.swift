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
    
    private var accounts: [AccountsListItemCell.ViewModel] = []
    
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
            
            let vmToAdd: [AccountsListItemCell.ViewModel] = filteredWalletsChangeSet.toAdd.map(self.transform)
            let indicesToRemove: IndexSet = IndexSet(
                self.accounts
                    .enumerated()
                    .filter { accountEnumeration in
                        filteredWalletsChangeSet.toRemove.contains(where: { $0.id == accountEnumeration.element.id }) ||
                        updatedDeletedIds.contains(accountEnumeration.element.id)
                    }
                    .map { $0.offset }
            )
            let updateVM: [(Int, AccountsListItemCell.ViewModel)] = filteredWalletsChangeSet.toUpdate.compactMap { updateWallet in
                guard let updateIdx = self.accounts.firstIndex(where: { $0.id == updateWallet.id }) else { return nil }
                let updateVM: AccountsListItemCell.ViewModel = self.transform(updateWallet)
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
                if updateVM.count == 1 {
                    UIView.setAnimationsEnabled(false)
                    self.view?.tableView.beginUpdates()
                    let cell = self.view?.tableView.cellForRow(at: IndexPath(item: updateVM.first!.0, section: .zero)) as? AccountsListItemCell
                    cell?.update(collection: updateVM.first!.1.derivedItemViewModels)
                    cell?.update(name: updateVM.first!.1.accountName)
//                    cell?.layoutSubviews()
                    self.view?.tableView.endUpdates()
                    UIView.setAnimationsEnabled(true)
//                    self.view?.tableView.reloadRows(at: [IndexPath(item: updateVM.first!.0, section: .zero)], with: .none)
//                    self.view?.tableView.reconfigureRows(at: <#T##[IndexPath]#>)
                    
                }
                if indicesToRemove.count != .zero {
//                    self.view?.tableView.beginUpdates()
                    let indexPaths = indicesToRemove.map { IndexPath(item: $0, section: .zero) }
                    self.view?.tableView.deleteRows(at: indexPaths, with: .none)
//                    self.view?.tableView.endUpdates()
                }
                
                if vmToAdd.count == 1 {
//                    self.view?.tableView.beginUpdates()
                    self.view?.tableView.insertRows(
                        at: [IndexPath(row: self.accounts.count - 1, section: .zero)], with: .fade
                    )
//                    self.view?.tableView.endUpdates()
                }
                if vmToAdd.count > 1 {
                    self.view?.tableView.reloadData()
                }
            }
        }
    }
    
    private func scrollToWalletAndBlink(walletId: String) {
        self.view?.tableView.reloadData()
    }

    private func transform(_ wallet: TokenaryWallet) -> AccountsListItemCell.ViewModel {
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

        return AccountsListItemCell.ViewModel(
            id: wallet.id,
            icon: icon,
            accountName: wallet.name,
            accountAddress: wallet.isMnemonic ? nil : wallet[.address] ?? nil,
            chainType: wallet.isMnemonic ? nil : privateKeyChainType!,
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
            iconShadowColor: .black,
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
        switch accounts[indexPath.row].derivedItemViewModels.count {
        case 3:
            return (76 + 12 + 50)
        case 2, 1:
            return 38 + 6 + 40 + 10
        default:
            return 40 + 10
        }
    }
}

// MARK: - AccountsListPresenter + UITableViewDataSource

extension AccountsListPresenter {    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        accounts.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountsListItemCell.self, for: indexPath)
        DispatchQueue.main.async {
            cell.configure(with: self.accounts[indexPath.row])
            cell.attachedWallet = WalletsManager.shared.getWallet(id: self.accounts[indexPath.row].id)
        }
        return cell
    }
}
