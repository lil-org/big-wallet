// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct AccountsListView: View {
    @EnvironmentObject
    var stateProvider: AccountsListStateProvider
    
    @State
    private var arePreferencesPresented: Bool = false
    @State
    private var isShareInvitePresented: Bool = false
    
    public var body: some View {
//        NavigationView {
            AccountsListContentHolderView()
                .toolbar { self.leadingNavigationBarItems; self.trailingNavigationBarItems }
//                .navigationBarItems(leading: self.leadingNavigationBarItems, trailing: self.trailingNavigationBarItems)
                .navigationTitle("All Accounts")
                .environmentObject(self.stateProvider)
//        }
//        .padding(.top, -40)
//        .edgesIgnoringSafeArea(.top)
        .navigationViewStyle(.automatic)
//        .navigationViewStyle(StackNavigationViewStyle())
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
//        .confirmationDialog(Strings.addAccount, isPresented: $stateProvider.isAddAccountPresented, actions: {
//            Button("🌱 " + Strings.createNew, role: .none) { self.stateProvider.didTapCreateNewMnemonicWallet() }
//            Button(Strings.importExisting, role: .none) { self.stateProvider.didTapImportExistingAccount() }
//            Button(Strings.cancel, role: .cancel, action: {})
//        })
//        .confirmationDialog(String.empty, isPresented: $arePreferencesPresented, actions: {
//            Button(Strings.viewOnTwitter, role: .none) { LinkHelper.open(URL.twitter) }
//            Button(Strings.viewOnGithub, role: .none) { LinkHelper.open(URL.github) }
//            Button(Strings.dropUsALine.withEllipsis, role: .none) { LinkHelper.open(URL.email) }
//            Button(Strings.shareInvite.withEllipsis, role: .none) { self.isShareInvitePresented.toggle() }
//            Button(Strings.howToEnableSafariExtension, role: .none) { LinkHelper.open(URL.iosSafariGuide) }
//            Button(Strings.cancel, role: .cancel, action: {})
//        }, message: { // Custom view-hierarchy doesn't work here
//            Text("❤️ " + Strings.tokenary + " ❤️" + Symbols.newLine + "Show love 4269.eth")
//        })
#if canImport(UIKit)
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
#elseif canImport(AppKit)
        .activityShare(
            isPresented: $isShareInvitePresented,
            config: .init(
                sharingItems: [URL.appStore],
                excludedSharingServiceNames: [
                    .addToSafariReadingList, .sendViaAirDrop, .useAsDesktopPicture,
                    .addToIPhoto, .addToAperture,
                ]
            )
        )
#endif
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

struct AccountsListView_Previews: PreviewProvider {
    static var stateProvider = AccountsListStateProvider(mode: .mainScreen)
    
    static var previews: some View {
        let view = VStack {
            Text("AllAccounts")
                .font(.title)
            AccountsListContentHolderView()
                .previewLayout(.device)
                .environmentObject(stateProvider)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)

        return Group {
            view
                .environment(\.colorScheme, .light)
                .frame(width: 250, height: 350)
//            view
//                .environment(\.colorScheme, .dark)
//                .frame(width: 250, height: 350)
        }
    }
}
