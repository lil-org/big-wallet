// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

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
    private var selectedChain: ChainType? {
        if case let .choseAccount(forChain: supportedChain) = stateProvider.mode {
            return supportedChain
        } else {
            return nil
        }
    }
    
    private var isProviderNetworkFilterButtonShown: Bool {
        if selectedChain == .ethereum {
            return true
        } else {
            return false
        }
    }
    
    var body: some View {
        if stateProvider.accounts.isEmpty {
            emptyViewState
        } else {
            ScrollViewReader { scrollProxy in
                List {
                    #if canImport(UIKit)
                    networkFilterButton
                    #elseif canImport(AppKit)
                    Divider()
                    #endif
                    ForEach($stateProvider.accounts) { $account in
                        AccountItemView(
                            viewModel: $account
                        )
                        .listRowInsets(.init(top: .zero, leading: .zero, bottom: .zero, trailing: .zero))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(
                                role: .destructive,
                                action: {
                                    if let walletToRemove = stateProvider.wallets.first(
                                        where: { $0.id == account.id }
                                    ) {
                                        stateProvider.askBeforeRemoving(wallet: walletToRemove)
                                    }
                                },
                                label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            )
                            .tint(Color.orange)
                        }
                        #if canImport(AppKit)
                        Divider()
                        #endif
                    }
                }
                .background(Color.mainBackground.ignoresSafeArea())
                .listStyle(PlainListStyle())
                .onChange(of: stateProvider.scrollToWalletId) { newValue in
                    guard
                        newValue != nil,
                        let accountToScrollTo = stateProvider.accounts.first(where: { $0.id == newValue })
                    else { return }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            scrollProxy.scrollTo(accountToScrollTo.id, anchor: .bottom)
                        }
                    }
                }
                .confirmationDialog(
                    providerNetworksDialogTitle,
                    isPresented: $areProviderNetworksPresented,
                    titleVisibility: .visible,
                    actions: {
                        providerNetworkActions
                        Button(Strings.cancel, role: .cancel, action: {})
                    }
                )
                .confirmationDialog(
                    providerTestnetsDialogTitle,
                    isPresented: $areProviderTestnetsPresented,
                    titleVisibility: .visible,
                    actions: {
                        providerTestnetActions
                        Button(Strings.cancel, role: .cancel, action: {})
                    }
                )
                .addToGlobalOverlay( // ToDo: This requires a normal pop-up heap manager
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
                stateProvider.didTapCreateNewMnemonicWallet()
            } label: {
                Text(Strings.createNew)
                    .foregroundColor(Color.mainText)
                    .font(.system(size: 21, weight: .bold))
            }
            .buttonStyle(.plain)
            .frame(height: 44, alignment: .leading)
            Divider()
            Button(role: .none) {
                stateProvider.didTapImportExistingAccount()
            } label: {
                Text(Strings.importExisting)
                    .foregroundColor(Color.mainText)
                    .font(.system(size: 21, weight: .bold))
            }
            .buttonStyle(.plain)
            .frame(height: 44, alignment: .leading)
            Divider()
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        #endif
    }
    
    @ViewBuilder
    private var networkFilterButton: some View {
        if isProviderNetworkFilterButtonShown {
            HStack {
                Button(action: { areProviderNetworksPresented.toggle() }) {
                    HStack {
                        Spacer()
                        Text(selectedNetworkButtonTitle)
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
            case let .choseAccount(forChain: supportedChain) = stateProvider.mode,
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
                    selectedNetwork = network
                    stateProvider.didSelect(chain: network)
                }
            }
            Button(Strings.testnets.withEllipsis) {
                areProviderTestnetsPresented.toggle()
            }
        }
    }
    
    private var providerTestnetActions: some View {
        Unwrap(self.selectedChain) { selectedChain in
            ForEach(EthereumChain.testnets, id: \.self) { network in
                Button(network.title) {
                    selectedNetwork = network
                    stateProvider.didSelect(chain: network)
                }
            }
        }
    }
}

#if canImport(AppKit)
/// While this is terrible, but SwiftUI.List is bugged for macOS, and it sets two uncontrollable internal layers(NSTableView) background colors.
extension NSTableView {
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        backgroundColor = NSColor.clear
        enclosingScrollView!.drawsBackground = false
    }
}
#endif
