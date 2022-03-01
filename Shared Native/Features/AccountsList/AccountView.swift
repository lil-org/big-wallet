// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

struct AccountView: View {
    struct ViewModel: Identifiable, Equatable {
        let id: String
        let icon: Image
        let isMnemonicBased: Bool
        let accountAddress: String?
        let accountName: String
        var mnemonicDerivedViewModels: [MnemonicDerivedAccountView.ViewModel]
    }
    
    @Binding
    var viewModel: ViewModel
    
    @Binding
    var showToastOverlay: Bool
    
    @Binding
    var selectedElementId: String?
    
    var body: some View {
        VStack {
            HStack(spacing: 12) {
                self.viewModel.icon
                    .resizable()
                    .cornerRadius(15)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    
                VStack(alignment: .leading) {
                    Text(self.viewModel.accountName)
                        .font(.system(size: 19, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if self.viewModel.isMnemonicBased {
                        Text("Multi-Coin wallet")
                            .font(.system(size: 15, weight: .regular))
                            .lineLimit(1)
                    } else if let accountAddress = self.viewModel.accountAddress {
                        Text(accountAddress)
                            .font(.system(size: 15, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button(action: { self.moreAction() }) {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                        .padding([.leading, .trailing], 20)
                        .padding([.top, .bottom], 10)
                        .background(
                            Rectangle().fill(.clear)
                        )
                }
                .buttonStyle(DimmingButtonStyle())
                .offset(x: 15)
            }
            
            if self.viewModel.isMnemonicBased && self.viewModel.mnemonicDerivedViewModels.count != .zero {
                self.derivedAccountsGrid
            }
        }
    }
    
    private var derivedAccountsGrid: some View {
        WrappingStack {
            ForEach($viewModel.mnemonicDerivedViewModels, id: \.id) { $mnemonicDerivedViewModel in
                MnemonicDerivedAccountView(viewModel: $mnemonicDerivedViewModel, showToastOverlay: $showToastOverlay)
            }
        }
        .wrappingStackStyle(
            hSpacing: 8, vSpacing: 8, alignment: .leading
        )
        .expandableGridStyle(
            hSpacing: 10, vSpacing: 10
        )
    }
    
    private func moreAction() {
        self.selectedElementId = viewModel.id
    }
}

struct AccountView_Previews: PreviewProvider {
    static var previews: some View {
        AccountView(
            viewModel: .constant(.init(
                id: "Some-ID",
                icon: Image("tez"),
                isMnemonicBased: true,
                accountAddress: "0x011b6e24ffb0b5f5fcc564cf4183c5bbbc96d515",
                accountName: "Some really good old name with comas,,, 🔥🔥🔥🔥🔥",
                mnemonicDerivedViewModels: []
            )),
            showToastOverlay: .constant(true),
            selectedElementId: .constant("false")
        )
    }
}
