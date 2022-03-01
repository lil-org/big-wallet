// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

// Задачи:
// notLoading from start elements
// check everything final, make mr
// top navigation padding ???
// very long loading time when deriving accounts - derivation time
// lag when updating names
//  Быстрая анимация при таче
//  Выравнивание элементов в WrappingStack-е
//  Работающая пагинация элементов в ExpandableGrid
// fix ipad 2 places
// update MR
// beta icon
// wix console stuff
// resolve todos
// MacOS integraion

struct AccountsListView: View {
    @EnvironmentObject
    var stateProvider: AccountsListStateProvider
    
    @State
    private var arePreferencesPresented: Bool = false
    @State
    private var isShareInvitePresented: Bool = false
    
    public var body: some View {
        NavigationView {
            AccountsListContentHolderView()
                .navigationBarItems(leading: self.leadingNavigationBarItems, trailing: self.trailingNavigationBarItems)
                .navigationTitle("All Accounts")
                .environmentObject(self.stateProvider)
        }
        .padding(.top, -40)
//        .edgesIgnoringSafeArea(.top)
        .navigationViewStyle(StackNavigationViewStyle())
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
        .confirmationDialog(Strings.addAccount, isPresented: $stateProvider.isAddAccountPresented, actions: {
            Button("🌱 " + Strings.createNew, role: .none) { self.stateProvider.didTapCreateNewMnemonicWallet() }
            Button(Strings.importExisting, role: .none) { self.stateProvider.didTapImportExistingAccount() }
            Button(Strings.cancel, role: .cancel, action: {})
        })
        .confirmationDialog(String.empty, isPresented: $arePreferencesPresented, actions: {
            Button(Strings.viewOnTwitter, role: .none) { UIApplication.shared.open(URL.twitter) }
            Button(Strings.viewOnGithub, role: .none) { UIApplication.shared.open(URL.github) }
            Button(Strings.dropUsALine.withEllipsis, role: .none) { UIApplication.shared.open(URL.email) }
            Button(Strings.shareInvite.withEllipsis, role: .none) { self.isShareInvitePresented.toggle() }
            Button(Strings.howToEnableSafariExtension, role: .none) { UIApplication.shared.open(URL.iosSafariGuide) }
            Button(Strings.cancel, role: .cancel, action: {})
        }, message: { // Custom view-hierarchy doesn't work here
            Text("❤️ " + Strings.tokenary + " ❤️" + Symbols.newLine + "Show love 4269.eth")
        })
        .activityShare(
            isPresented: $isShareInvitePresented,
            config: .init(
                activityItems: [URL.appStore],
                applicationActivities: nil,
                excludedActivityTypes: [
                    .addToReadingList, .airDrop, .assignToContact,
                    .openInIBooks, .postToFlickr, .postToVimeo,
                    .markupAsPDF
                ]
            )
        )
    }
    
    private var leadingNavigationBarItems: some View {
        HStack(alignment: .bottom) {
            switch self.stateProvider.mode {
            case .mainScreen: EmptyView()
            case .choseAccount(_):
                Button(action: { self.cancelAccountSelection() }) {
                    Text("Cancel")
                }
            }
        }
    }
    
    private var trailingNavigationBarItems: some View {
        HStack(alignment: .bottom) {
            switch self.stateProvider.mode {
            case .mainScreen:
                Spacer(minLength: 20)
                Button(action: { self.showPreferences() }) {
                    Image(systemName: "gearshape")
                }
            case .choseAccount(_): EmptyView()
            }
            Button(action: self.addAccount) {
                Image(systemName: "plus")
            }
        }
    }
    
    private func showPreferences() {
        self.arePreferencesPresented.toggle()
    }
    
    private func addAccount() {
        self.stateProvider.isAddAccountPresented.toggle()
    }
    
    private func cancelAccountSelection() {
        self.stateProvider.cancelButtonWasTapped()
    }
}
