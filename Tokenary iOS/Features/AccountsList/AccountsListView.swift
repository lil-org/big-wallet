// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct AccountsListView: View {
    @EnvironmentObject
    var stateProvider: AccountsListStateProvider
    
    @State
    private var arePreferencesPresented: Bool = false
    @State
    private var isShareInvitePresented: Bool = false
    @State
    private var shareButton: UIView?
    
    var body: some View {
        NavigationView {
            AccountsListContentHolderView()
                .environmentObject(stateProvider)
                .navigationBarTitle(Text(stateProvider.mode == .mainScreen ? "Accounts" : "Select Account"), displayMode: .large)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        leadingNavigationBarItems
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        trailingNavigationBarItems
                    }
                }
                .padding(.zero)
                .zIndex(1)
            Spacer()
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .confirmationDialog(String.empty, isPresented: $arePreferencesPresented, actions: {
            preferencesActionButtons // iOS
            Button(Strings.cancel, role: .cancel, action: {})
        }, message: { // Custom view-hierarchy doesn't work here
            Text("❤️ " + Strings.tokenary + " ❤️" + Symbols.newLine + "Show love 4269.eth")
        })
        .confirmationDialog(Strings.addAccount, isPresented: $stateProvider.isAddAccountDialogPresented, actions: {
            addAccountActionButtons // iOS
            Button(Strings.cancel, role: .cancel, action: {})
        })
        .popover( // iPadOS
            isPresented: $stateProvider.isAddAccountPopoverPresented,
            attachmentAnchor: .point(stateProvider.touchAnchor),
            arrowEdge: .bottom,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    createNewButton
                    Divider()
                    importExistingButton
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Color.mainText)
            }
        )
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
            ),
            bindView: $shareButton
        )
    }
    
    private var leadingNavigationBarItems: some View {
        HStack(alignment: .bottom) {
            switch stateProvider.mode {
            case .mainScreen:
                EmptyView()
            case .choseAccount(_):
                Button(action: { stateProvider.cancelButtonWasTapped() }) {
                    Text("Cancel")
                }
            }
        }
    }
    
    @ViewBuilder
    private var trailingNavigationBarItems: some View {
        switch stateProvider.mode {
        case .mainScreen:
            if UIDevice.isPad {
                Menu {
                    preferencesActionButtons
                    Divider()
                    let sendLoveString =
                        String(repeating: Symbols.nbsp, count: 10) + "❤️ " + Strings.tokenary + " ❤️" +
                        Symbols.newLine + String(repeating: Symbols.nbsp, count: 7) + "Show love 4269.eth"
                    Text(sendLoveString)
                } label: {
                    Image(systemName: "gearshape")
                        .background(UIViewBinding(as: $shareButton))
                }
            } else {
                Button(action: { arePreferencesPresented.toggle() }) {
                    Image(systemName: "gearshape")
                }
            }
            Spacer(minLength: 20)
        case .choseAccount(_):
            EmptyView()
        }
        if UIDevice.isPad {
            Menu {
                addAccountActionButtons
            } label: {
                Image(systemName: "plus")
            }
        } else {
            Button(action: { stateProvider.isAddAccountDialogPresented.toggle() }) {
                Image(systemName: "plus")
            }
        }
    }
    
    @ViewBuilder
    private var preferencesActionButtons: some View {
        Button {
            LinkHelper.open(URL.twitter)
        } label: {
            Text(Strings.viewOnTwitter)
            Image(packageResource: "twitter", ofType: "png")
                .imageScale(.large)
        }
        Button {
            LinkHelper.open(URL.github)
        } label: {
            Text(Strings.viewOnGithub)
            Image(packageResource: "github", ofType: "png")
                .imageScale(.large)
        }
        Button {
            LinkHelper.open(URL.email)
        } label: {
            Text(Strings.dropUsALine.withEllipsis)
            Image(systemName: "at")
                .imageScale(.large)
        }
        Button {
            isShareInvitePresented.toggle()
        } label: {
            Text(Strings.shareInvite.withEllipsis)
            Image(systemName: "square.and.arrow.up")
                .imageScale(.large)
        }
        Button {
            LinkHelper.open(URL.iosSafariGuide)
        } label: {
            Text(Strings.howToEnableSafariExtension)
            Image(systemName: "info.circle")
                .imageScale(.large)
        }
    }
    
    private var createNewButton: some View {
        Button(Strings.createNew, role: .none) {
            if UIDevice.isPad {
                stateProvider.isAddAccountPopoverPresented = false
            } else {
                stateProvider.isAddAccountDialogPresented = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                stateProvider.didTapCreateNewMnemonicWallet()
            }
        }
    }
    
    private var importExistingButton: some View {
        Button(Strings.importExisting, role: .none) {
            if UIDevice.isPad {
                stateProvider.isAddAccountPopoverPresented = false
            } else {
                stateProvider.isAddAccountDialogPresented = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                stateProvider.didTapImportExistingAccount()
            }
        }
    }
    
    @ViewBuilder
    private var addAccountActionButtons: some View {
        createNewButton
        importExistingButton
    }
}

struct AccountsListView_Previews: PreviewProvider {
    static var stateProvider = AccountsListStateProvider(mode: .mainScreen)
    
    static var previews: some View {
        Group {
            AccountsListContentHolderView()
                .previewLayout(.device)
                .environmentObject(stateProvider)
                .environment(\.colorScheme, .light)
                .frame(width: 250, height: 350)
        }
    }
}
