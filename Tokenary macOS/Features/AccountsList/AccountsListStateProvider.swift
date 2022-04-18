// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

protocol AccountsListStateProviderInput: AnyObject {
    var filteredWallets: [TokenaryWallet] { get }
    
    func updateAccounts(with walletsChangeSet: WalletsManager.TokenaryWalletChangeSet)
    func scrollToWalletAndBlink(walletId: String)
}

protocol AccountsListStateProviderOutput: AnyObject {
    func didTapCreateNewMnemonicWallet()
    func didTapImportExistingAccount()
    func didTapRemove(wallet: TokenaryWallet)
    func cancelButtonWasTapped()
    func didSelect(chain: EthereumChain)
    func didTapExport(wallet: TokenaryWallet)
    func askBeforeRemoving(wallet: TokenaryWallet)
    func didSelect(wallet: TokenaryWallet)
    func didTapRename(previousName: String, completion: @escaping (String?) -> Void)
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet)
}

class AccountsListStateProvider: ObservableObject {
    @Published
    var accounts: [AccountsListSectionHeaderView.ViewModel] = []
    
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
            
            let vmToAdd: [AccountsListSectionHeaderView.ViewModel] = filteredWalletsChangeSet.toAdd.map(self.transform)
            let indicesToRemove: IndexSet = IndexSet(
                self.accounts
                    .enumerated()
                    .filter { accountEnumeration in
                        filteredWalletsChangeSet.toRemove.contains(where: { $0.id == accountEnumeration.element.id }) ||
                        updatedDeletedIds.contains(accountEnumeration.element.id)
                    }
                    .map { $0.offset }
            )
            let updateVM: [(Int, AccountsListSectionHeaderView.ViewModel)] = filteredWalletsChangeSet.toUpdate.compactMap { updateWallet in
                guard let updateIdx = self.accounts.firstIndex(where: { $0.id == updateWallet.id }) else { return nil }
                let updateVM: AccountsListSectionHeaderView.ViewModel = self.transform(updateWallet)
                return (updateIdx, updateVM)
            }
            
            DispatchQueue.main.async {
                for (updateIdx, accountVM) in updateVM {
                    self.accounts[updateIdx] = accountVM
                }
                self.accounts.remove(atOffsets: indicesToRemove)
                self.accounts.append(contentsOf: vmToAdd)
                if vmToAdd.count == 1 && updateVM.count == .zero && indicesToRemove.count == .zero {
                    self.scrollToWalletAndBlink(walletId: vmToAdd.first!.id)
                }
            }
        }
    }

    var filteredWallets: [TokenaryWallet] {
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
    
    // iPad -> popover, iPhone -> dialog
    @Published
    var isAddAccountPopoverPresented: Bool = false
    @Published
    var isAddAccountDialogPresented: Bool = false
    
    var touchAnchor: UnitPoint = .zero
    
    @Published
    var showToastOverlay: Bool = false
    
    @Published
    var mode: AccountsListMode
    
    @Published
    var scrollToAccountIndex: Int?
    
    weak var output: AccountsListStateProviderOutput?
    
    init(mode: AccountsListMode) {
        self.mode = mode
    }

    private func transform(_ wallet: TokenaryWallet) -> AccountsListSectionHeaderView.ViewModel {
        let icon: Image
        if wallet.isMnemonic {
            if wallet.associatedMetadata.allChains.contains(.ethereum) {
                icon = Image(
                    Blockies(seed: wallet[.ethereum, .address]??.lowercased(), size: 10).createImage(),
                    defaultImage: "multiChainGrid"
                )
            } else {
                icon = Image("multiChainGrid")
            }
        } else {
            let privateKeyChainType = wallet.associatedMetadata.privateKeyChain!
            if privateKeyChainType == .ethereum {
                icon = Image(
                    Blockies(seed: wallet[.address]??.lowercased(), size: 10).createImage(),
                    defaultImage: "multiChainGrid"
                )
            } else {
                icon = Image("multiChainGrid")
            }
        }
        return AccountsListSectionHeaderView.ViewModel(
            id: wallet.id,
            icon: icon,
            accountName: wallet.name,
            mnemonicDerivedViewModels: transform(wallet).sorted(by: { $0.title > $1.title })
        )
    }
    
    private func transform(_ wallet: TokenaryWallet) -> [AccountsListDerivedItemView.ViewModel] {
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
    
    private func transform(
        _ wallet: TokenaryWallet, chain: ChainType
    ) -> AccountsListDerivedItemView.ViewModel {
        let address: String?
        if wallet.isMnemonic {
            address = wallet[chain, .address] ?? .empty
        } else {
            address = wallet[.address] ?? .empty
        }
        return AccountsListDerivedItemView.ViewModel(
            walletId: wallet.id,
            icon: Image(chain.iconName),
            chain: chain,
            accountAddress: address ?? .empty
        )
    }
}

extension AccountsListStateProvider: AccountsListStateProviderInput {
    func scrollToWalletAndBlink(walletId: String) {
        guard let accountIdx = accounts.firstIndex(where: { $0.id == walletId }) else { return }
        scrollToAccountIndex = accountIdx
        accounts[accountIdx].preformBlink = true
    }
}

extension AccountsListStateProvider: AccountsListStateProviderOutput {
    func didTapCreateNewMnemonicWallet() { output?.didTapCreateNewMnemonicWallet() }
    
    func didTapImportExistingAccount() { output?.didTapImportExistingAccount() }
    
    func didTapRemove(wallet: TokenaryWallet) { output?.didTapRemove(wallet: wallet) }
    
    func cancelButtonWasTapped() { output?.cancelButtonWasTapped() }
    
    func didSelect(chain: EthereumChain) { output?.didSelect(chain: chain) }
    
    func didTapExport(wallet: TokenaryWallet) { output?.didTapExport(wallet: wallet) }
    
    func askBeforeRemoving(wallet: TokenaryWallet) { output?.askBeforeRemoving(wallet: wallet) }
    
    func didSelect(wallet: TokenaryWallet) { output?.didSelect(wallet: wallet) }
    
    func didTapRename(previousName: String, completion: @escaping (String?) -> Void) {
        output?.didTapRename(previousName: previousName, completion: completion)
    }
    
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet) {
        output?.didTapReconfigureAccountsIn(wallet: wallet)
    }
}
