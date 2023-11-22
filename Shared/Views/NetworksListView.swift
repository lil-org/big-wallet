// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct NetworksListView: View {
    
    private let mainnets = Networks.mainnets
    private let testnets = Networks.testnets
    private let pinned = Networks.pinned
    
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedNetwork: EthereumNetwork?
    
    private let completion: ((EthereumNetwork?) -> Void)
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    networkSection(networks: pinned, title: Strings.pinned)
                    networkSection(networks: mainnets)
                    networkSection(networks: testnets, title: Strings.testnets)
                }
            }
            .navigationBarTitle(Strings.selectNetwork, displayMode: .large)
            .navigationBarItems(leading: Button(action: {
                completion(selectedNetwork)
                presentationMode.wrappedValue.dismiss() }) {
                    Text(Strings.done).bold()
            }.disabled(selectedNetwork == nil))
        }
    }
    
    init(selectedNetwork: EthereumNetwork?, completion: @escaping ((EthereumNetwork?) -> Void)) {
        self._selectedNetwork = State(initialValue: selectedNetwork)
        self.completion = completion
    }
    
    @ViewBuilder
    private func networkSection(networks: [EthereumNetwork], title: String? = nil) -> some View {
        Section(header: title.map { Text($0) }) {
            ForEach(networks, id: \.self) { network in
                HStack {
                    Text(network.name)
                    Spacer()
                    if selectedNetwork?.chainId == network.chainId {
                        Image.checkmark.foregroundStyle(.selection)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedNetwork?.chainId == network.chainId {
                        selectedNetwork = nil
                    } else {
                        selectedNetwork = network
                    }
                }
            }
        }
    }
    
}
