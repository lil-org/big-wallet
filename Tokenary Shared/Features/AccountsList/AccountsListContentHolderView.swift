// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
//#elseif canImport(AppKit)
//        .activityShare(
//            isPresented: $isShareInvitePresented,
//            config: .init(
//                sharingItems: [URL.appStore],
//                excludedSharingServiceNames: [
//                    .addToSafariReadingList, .sendViaAirDrop, .useAsDesktopPicture,
//                    .addToIPhoto, .addToAperture,
//                ]
//            )
//        )

//haptic(type: .success)
struct AccountsListContentHolderView: View {
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    /// Network selected when choosing account
    private var selectedNetwork: EthereumChain?
    
    @State
    private var areProviderNetworksPresented: Bool = false
    @State
    private var areProviderTestnetsPresented: Bool = false
    
    /// Chain for which the networks are going to be shown
    /// Currently, when the mode is `.choseAccount(_)`, but we still have no network, we don't allow to filter
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
    
    var body: some View {
        if self.stateProvider.accounts.isEmpty {
            self.emptyViewState
        } else {
            ScrollViewReader { scrollProxy in
                List {
                    #if canImport(UIKit)
                    self.networkFilterButton
                    #endif
                    ForEach($stateProvider.accounts) { $account in
                        AccountItemView(
                            viewModel: $account
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
                    }
                }
                .listStyle(PlainListStyle())
                .animation(.default, value: self.stateProvider.accounts)
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
                .confirmationDialog(
                    self.providerNetworksDialogTitle,
                    isPresented: self.$areProviderNetworksPresented,
                    titleVisibility: .visible,
                    actions: {
                        self.providerNetworkActions
                        Button(Strings.cancel, role: .cancel, action: {})
                    }
                )
                .confirmationDialog(
                    self.providerTestnetsDialogTitle,
                    isPresented: self.$areProviderTestnetsPresented,
                    titleVisibility: .visible,
                    actions: {
                        self.providerTestnetActions
                        Button(Strings.cancel, role: .cancel, action: {})
                    }
                )
                .addToGlobalOverlay( // ToDo(@pettrk): This requires a normal pop-up heap manager
                    overlayView:
                        SimpleToast(
                            viewModel: .init(
                                title: "Address copied to clipboard!",
                                icon: Image(systemName: "checkmark")
                            ),
                            isShown: $stateProvider.showToastOverlay
                        ),
                    isShown: $stateProvider.showToastOverlay
                )
            }
        }
    }
    
    private var emptyViewState: some View {
        #if canImport(UIKit)
        List {
            EmptyView()
        }
        .listStyle(PlainListStyle())
        #elseif canImport(AppKit)
        List {
            Button(role: .none) {
                self.stateProvider.didTapCreateNewMnemonicWallet()
            } label: {
                Text(Strings.createNew)
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
    }
    
    @ViewBuilder
    private var networkFilterButton: some View {
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
    }
    
    private var selectedNetworkButtonTitle: String {
        if let selectedNetwork = self.selectedNetwork {
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
}
