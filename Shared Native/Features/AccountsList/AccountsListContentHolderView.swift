// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct AccountsListContentHolderView: View {
    @EnvironmentObject
    var stateProvider: AccountsListStateProvider
    
    @State
    var selectedWalletId: String?
    
    @State
    private var chainToShowActionsFor: SupportedChainType?
    
    @State
    private var selectedNetwork: EthereumChain?
    
    @State
    private var areActionsForDerivedAccountPresented: Bool = false
    @State
    private var areActionsForWalletPresented: Bool = false
    
    @State
    private var areProviderNetworksPresented: Bool = false
    @State
    private var areProviderTestnetsPresented: Bool = false
    
    var body: some View {
//        Group {
            if self.stateProvider.accounts.isEmpty {
                EmptyView()
            } else {
                List {
                    if self.isProviderNetworkFilterButtonShown {
                        HStack {
                            Button(action: { self.areProviderNetworksPresented.toggle() }) {
                                HStack {
                                    Spacer()
                                    Text(self.selectedNetworkButtonTitle)
                                    Image(systemName: "chevron.down")
                                    Spacer()
                                }
                            }
                            .buttonStyle(
                                ButtonWithBackgroundStyle(
                                    backgroundColor: Color(UIColor.systemGray4), foregroundColor: .blue
                                )
                            )
                            .frame(height: 52)
                        }
                        .padding([.horizontal], 20)
                        .padding([.vertical], 8)
                        .listRowInsets(EdgeInsets())
                    }
                    ForEach($stateProvider.accounts) { $account in
                        AccountView(
                            viewModel: $account,
                            showToastOverlay: $stateProvider.showToastOverlay,
                            selectedElementId: $selectedWalletId
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(
                                role: .destructive,
                                action: {
                                    if let walletToRemove = self.stateProvider.wallets.first(
                                        where: { $0.id == account.id }
                                    ) {
                                        self.stateProvider.askBeforeRemoving(wallet: walletToRemove)
                                    }
                                },
                                label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            )
                            .tint(Color(UIColor.systemRed))
                        }
                        .confirmationDialog(
                            self.actionsForWalletDialogTitle,
                            isPresented: $areActionsForWalletPresented,
                            titleVisibility: .visible,
                            actions: {
                                Button("Rename Wallet", role: .none) {
                                    if let selectedWallet = self.stateProvider.selectedWallet {
                                        self.stateProvider.didTapRename(previousName: selectedWallet.name) { newName in
                                            if let newName = newName {
                                                try? WalletsManager.shared.rename(
                                                    wallet: selectedWallet, newName: newName
                                                )
                                            }
                                        }
                                    }
                                }
                                self.specialWalletActions
                                Button(Strings.showWalletKey, role: .none) {
                                    if let selectedWallet = self.stateProvider.selectedWallet {
                                        self.stateProvider.didTapExport(wallet: selectedWallet)
                                    }
                                }
                                Button(Strings.removeWallet, role: .destructive) {
                                    if let selectedWallet = self.stateProvider.selectedWallet {
                                        self.stateProvider.didTapRemove(wallet: selectedWallet)
                                    }
                                }
                                Button(Strings.cancel, role: .cancel, action: {})
                            }
                        )
                        .confirmationDialog(
                            self.actionsForDerivedAccountDialogTitle,
                            isPresented: $areActionsForDerivedAccountPresented,
                            titleVisibility: .visible,
                            actions: {
                                self.derivedAccountActions
                            }
                        )
                    }
                }
                .listStyle(PlainListStyle())
                .animation(.default, value: self.stateProvider.accounts)
                .confirmationDialog(
                    self.providerNetworksDialogTitle,
                    isPresented: $areProviderNetworksPresented,
                    titleVisibility: .visible,
                    actions: {
                        self.providerNetworkActions
                        Button(Strings.cancel, role: .cancel, action: {})
                    }
                )
                .confirmationDialog(
                    self.providerTestnetsDialogTitle,
                    isPresented: $areProviderTestnetsPresented,
                    titleVisibility: .visible,
                    actions: {
                        self.providerTestnetActions
                        Button(Strings.cancel, role: .cancel, action: {})
                    }
                )
                .onChange(of: self.selectedWalletId) { newValue in
                    guard newValue != nil else { return  }
                    self.stateProvider.selectedWallet = self.stateProvider.wallets.first(
                        where: { $0.id == newValue }
                    )
                    self.areActionsForWalletPresented.toggle()
                    self.selectedWalletId = nil
                }
            }
//        }
    }
    
    private var selectedChain: SupportedChainType? {
        if case let .choseAccount(forChain: supportedChain) = self.stateProvider.mode {
            return supportedChain
        } else {
            return nil
        }
    }
    
    private var isProviderNetworkFilterButtonShown: Bool {
        if self.selectedChain == .ethereum {
            return true
        } else {
            return false
        }
    }
    
    private var selectedNetworkButtonTitle: String {
        if let selectedNetwork = selectedNetwork {
            return selectedNetwork.title
        } else if
            case let .choseAccount(forChain: supportedChain) = self.stateProvider.mode,
            let supportedChain = supportedChain
        {
            return supportedChain.title
        } else {
            return .empty
        }
    }
    
    private var actionsForWalletDialogTitle: String {
        if let address = self.stateProvider.selectedWallet?[.address] ?? nil {
            return address
        } else {
            return "Mnemonic wallet"
        }
    }
    
    private var actionsForDerivedAccountDialogTitle: String {
        if
            let chainToShowActionsFor = self.chainToShowActionsFor,
            let address = self.stateProvider.selectedWallet?[chainToShowActionsFor, .address] ?? nil {
            return address
        } else {
            let chainToShowActionsFor = self.chainToShowActionsFor ?? .ethereum
            return "\(chainToShowActionsFor.title) actions"
        }
    }
    
    private var providerTestnetsDialogTitle: String {
        if let selectedChain = self.selectedChain {
            return "Select \(selectedChain.title) testnet"
        } else {
            return "Select testnet"
        }
    }
    
    private var providerNetworksDialogTitle: String {
        if let selectedChain = self.selectedChain {
            return "Select \(selectedChain.title) network"
        } else {
            return "Select network"
        }
    }
    
    private func titleForChainButton(_ chain: SupportedChainType) -> String {
        switch chain {
        case .ethereum:
            return Strings.viewOnEtherScan
        case .tezos:
            return Strings.viewOnTezosScan
        case .solana:
            return Strings.viewOnSolanaScan
        }
    }
    
    private var providerNetworkActions: some View {
        Unwrap(self.selectedChain) { selectedChain in
            ForEach(EthereumChain.mainnets, id: \.self) { network in
                Button(network.title, role: .none, action: {
                    self.selectedNetwork = network
                    self.stateProvider.didSelect(chain: network)
                })
            }
            Button(Strings.testnets.withEllipsis, role: .none) {
                self.areProviderTestnetsPresented.toggle()
            }
        }
    }
    
    private var providerTestnetActions: some View {
        Unwrap(self.selectedChain) { selectedChain in
            ForEach(EthereumChain.testnets, id: \.self) { network in
                Button(network.title, role: .none, action: {
                    self.selectedNetwork = network
                    self.stateProvider.didSelect(chain: network)
                })
            }
        }
    }
    
    private var specialWalletActions: some View {
        Unwrap(self.stateProvider.selectedWallet) { selectedWallet in
            if selectedWallet.isMnemonic {
                self.mnemonicWalletActions
            } else {
                self.privateKeyWalletActions
            }
        }
    }
    
    private var mnemonicWalletActions: some View {
        Unwrap(self.stateProvider.selectedWallet) { selectedWallet in
            Button("Configure accounts") {
                self.stateProvider.didTapReconfigureAccountsIn(wallet: selectedWallet)
            }
            ForEach(selectedWallet.associatedMetadata.walletDerivationType.chainTypes, id: \.self) { chainType in
                Button("Show \(chainType.title) account actions", role: .none) {
                    self.chainToShowActionsFor = chainType
                    self.areActionsForDerivedAccountPresented.toggle()
                }
            }
        }
    }
    
    private var privateKeyWalletActions: some View {
        Unwrap(self.stateProvider.selectedWallet) { selectedWallet in
            let chainType = selectedWallet.associatedMetadata.walletDerivationType.chainTypes.first!
            Button(Strings.copyAddress, role: .none) {
                if let selectedWalletAddress = selectedWallet[.address] ?? nil {
                    UIPasteboard.general.string = selectedWalletAddress
                }
            }.keyboardShortcut(.defaultAction)
            Button(titleForChainButton(chainType), role: .none) {
                if let address = selectedWallet[.address] ?? nil {
                    UIApplication.shared.open(chainType.scanURL(address))
                }
            }
        }
    }
    
    private var derivedAccountActions: some View {
        Unwrap(self.stateProvider.selectedWallet) { selectedWallet in
            Unwrap(self.chainToShowActionsFor) { chainToShowActionsFor in
                Button(Strings.copyAddress) {
                    if let address = selectedWallet[chainToShowActionsFor, .address] ?? nil {
                        UIPasteboard.general.string = address
                    }
                }.keyboardShortcut(.defaultAction)
                Button(titleForChainButton(chainToShowActionsFor), role: .none) {
                    if let address = selectedWallet[chainToShowActionsFor, .address] ?? nil {
                        UIApplication.shared.open(chainToShowActionsFor.scanURL(address))
                    }
                }
                Button(Strings.cancel, role: .cancel, action: {})
            }
        }
    }
}
