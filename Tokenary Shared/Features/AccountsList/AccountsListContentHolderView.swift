// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct AccountsListContentHolderView: View {
    struct WalletAccountIdentifier: Equatable {
        let walletId: String
        let chainTitle: String
    }
    
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    private var moreActionsSelectedWalletId: String?
    @State
    private var chooseWalletAccountForActions: WalletAccountIdentifier?
    
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
        if self.stateProvider.accounts.isEmpty {
            #if canImport(UIKit)
            EmptyView()
            #elseif canImport(AppKit)
            List {
                Button(role: .none) {
                    self.stateProvider.didTapCreateNewMnemonicWallet()
                } label: {
                    Text("🌱  " + Strings.createNew)
                        .foregroundColor(Color(light: .black, dark: .white))
                        .font(.system(size: 21, weight: .bold))
                }
                .buttonStyle(.plain)
                .frame(height: 44, alignment: .leading)
                Button(role: .none) {
                    self.stateProvider.didTapImportExistingAccount()
                } label: {
                    Text(Strings.importExisting)
                        .foregroundColor(Color(light: .black, dark: .white))
                        .font(.system(size: 21, weight: .bold))
                }
                .buttonStyle(.plain)
                .frame(height: 44, alignment: .leading)
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            #endif
        } else {
            ScrollViewReader { scrollProxy in
            List {
                #if canImport(UIKit)
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
                                backgroundColor: Color.systemGray4, foregroundColor: .blue
                            )
                        )
                        .frame(height: 52)
                    }
                    .padding([.horizontal], 20)
                    .padding([.vertical], 8)
                    .listRowInsets(EdgeInsets())
                }
                #endif
                ForEach($stateProvider.accounts) { $account in
                    AccountView(
                        viewModel: $account,
                        showToastOverlay: $stateProvider.showToastOverlay,
                        moreActionsSelectedElementId: $moreActionsSelectedWalletId,
                        chooseWalletAccountForActions: $chooseWalletAccountForActions
                    )
                    .listRowInsets(EdgeInsets())
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
                        .tint(Color.systemRed)
                    }
                    #if canImport(AppKit)
                    .contextMenu {
                        Button("Rename Wallet") {
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
                        Button(Strings.showWalletKey) {
                            if let selectedWallet = self.stateProvider.selectedWallet {
                                self.stateProvider.didTapExport(wallet: selectedWallet)
                            }
                        }.keyboardShortcut("h", modifiers: [.control, .option, .command])
                        Divider()
                        Button(Strings.removeWallet) {
                            if let selectedWallet = self.stateProvider.selectedWallet {
                                self.stateProvider.didTapRemove(wallet: selectedWallet)
                            }
                        }.keyboardShortcut(.defaultAction)
                    }
                    #elseif canImport(UIKit)
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
                    #endif
                    .confirmationDialog(
                        self.actionsForDerivedAccountDialogTitle,
                        isPresented: $areActionsForDerivedAccountPresented,
                        titleVisibility: .visible,
                        actions: {
                            self.derivedAccountActions
                        }
                    )
                }
                .onChange(of: self.stateProvider.scrollToWalletId) { newValue in
                    guard
                        newValue != nil,
                        let accountToScrollTo = self.stateProvider.accounts.first(where: { $0.id == newValue })
                    else { return }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            scrollProxy.scrollTo(accountToScrollTo.id, anchor: .bottom)
                        }
                    }
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
            .onChange(of: self.moreActionsSelectedWalletId) { newValue in
                guard newValue != nil else { return  }
                self.stateProvider.selectedWallet = self.stateProvider.wallets.first(
                    where: { $0.id == newValue }
                )
                self.areActionsForWalletPresented.toggle()
                self.moreActionsSelectedWalletId = nil
            }
            .onChange(of: self.chooseWalletAccountForActions) { newValue in
                guard newValue != nil else { return }
                self.stateProvider.selectedWallet = self.stateProvider.wallets.first(
                    where: { $0.id == newValue?.walletId }
                )
                if let chainTitle = newValue?.chainTitle {
                    self.chainToShowActionsFor = SupportedChainType(rawValue: chainTitle.lowercased())
                }
                self.chooseWalletAccountForActions = nil
                self.areActionsForDerivedAccountPresented.toggle()
            }
            }
//                self.stateProvider.didSelect(wallet: selectedWallet) currently this is not done at all
        }
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
                Button(network.title) {
                    self.selectedNetwork = network
                    self.stateProvider.didSelect(chain: network)
                }
            }
            Button(Strings.testnets.withEllipsis) {
                self.areProviderTestnetsPresented.toggle()
            }
        }
    }
    
    private var providerTestnetActions: some View {
        Unwrap(self.selectedChain) { selectedChain in
            ForEach(EthereumChain.testnets, id: \.self) { network in
                Button(network.title) {
                    self.selectedNetwork = network
                    self.stateProvider.didSelect(chain: network)
                }
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
        }
    }
    
    private var privateKeyWalletActions: some View {
        Unwrap(self.stateProvider.selectedWallet) { selectedWallet in
            let chainType = selectedWallet.associatedMetadata.walletDerivationType.chainTypes.first!
            Button(Strings.copyAddress) {
                PasteboardHelper.setPlainNotNil(selectedWallet[.address] ?? nil)
            }.keyboardShortcut(.defaultAction)
            Button(self.titleForChainButton(chainType)) {
                if let address = selectedWallet[.address] ?? nil {
                    LinkHelper.open(chainType.scanURL(address))
                }
            }
        }
    }
    
    private var derivedAccountActions: some View {
        Unwrap(self.stateProvider.selectedWallet) { selectedWallet in
            Unwrap(self.chainToShowActionsFor) { chainToShowActionsFor in
                Button(Strings.copyAddress) {
                    PasteboardHelper.setPlainNotNil(selectedWallet[chainToShowActionsFor, .address] ?? nil)
                }.keyboardShortcut(.defaultAction)
                Button(titleForChainButton(chainToShowActionsFor)) {
                    if let address = selectedWallet[chainToShowActionsFor, .address] ?? nil {
                        LinkHelper.open(chainToShowActionsFor.scanURL(address))
                    }
                }
                Button(Strings.showWalletKey) {
                    self.stateProvider.didTapExport(wallet: selectedWallet)
                }
                if selectedWallet.associatedMetadata.walletDerivationType.chainTypes.count > 1 {
                    Button(Strings.removeWallet, role: .destructive) {
                        try? WalletsManager.shared.removeAccountIn(
                            wallet: selectedWallet,
                            account: chainToShowActionsFor
                        )
                    }
                }
                Button(Strings.cancel, role: .cancel, action: {})
            }
        }
    }
}
