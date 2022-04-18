// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct AccountsListContentHolderView: View {
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    var body: some View {
        if Keychain.shared.getAllWalletsIds().isEmpty {
            emptyViewState
        } else {
            ScrollViewReader { scrollProxy in
                List {
                    Divider()
                    ForEach($stateProvider.accounts) { $account in
                        AccountsListSectionHeaderView(
                            viewModel: $account
                        )
                        .listRowInsets(.init(top: .zero, leading: .zero, bottom: .zero, trailing: .zero))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(
                                role: .destructive,
                                action: {
                                    if let walletToRemove = WalletsManager.shared.getWallet(id: account.id) {
                                        stateProvider.askBeforeRemoving(wallet: walletToRemove)
                                    }
                                },
                                label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            )
                            .tint(Color.orange)
                        }
                        Divider()
                    }
                }
                .background(Color.mainBackground.ignoresSafeArea())
                .listStyle(.plain)
                .onChange(of: stateProvider.scrollToAccountIndex) { newValue in
                    guard let scrollToAccountIndex = newValue else { return }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            scrollProxy.scrollTo(stateProvider.accounts[scrollToAccountIndex].id, anchor: .bottom)
                        }
                    }
                }
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
    }
}

/// While this is terrible, but SwiftUI.List is bugged for macOS, and it sets two uncontrollable internal layers(NSTableView) background colors.
extension NSTableView {
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        backgroundColor = NSColor.clear
        enclosingScrollView!.drawsBackground = false
    }
}
