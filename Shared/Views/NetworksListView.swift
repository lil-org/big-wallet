// ∅ 2026 lil org

import SwiftUI

struct NetworksListView: View {
    
    private let mainnets = Networks.mainnets
    private let testnets = Networks.testnets
    private let custom = Networks.custom
    private let pinned = Networks.pinned
    
#if !os(macOS)
    @Environment(\.presentationMode) private var presentationMode
#endif
    @State private var selectedNetwork: EthereumNetwork?
    
    private let completion: ((EthereumNetwork?) -> Void)
    
    var body: some View {
#if os(macOS)
        VStack {
            list()
            HStack {
                Button(Strings.cancel) { completion(nil) }.keyboardShortcut(.cancelAction)
                Button(Strings.ok) { completion(selectedNetwork) }.keyboardShortcut(.defaultAction)
                    .disabled(selectedNetwork == nil)
            }.frame(height: 36).offset(CGSize(width: 0, height: -6))
        }
#else
        NavigationView {
            list(showsAdaptiveTitle: true)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(action: {
                completion(selectedNetwork)
                presentationMode.wrappedValue.dismiss() }) {
                    Text(Strings.done).bold()
                }.disabled(selectedNetwork == nil))
        }
#endif
    }
    
    init(selectedNetwork: EthereumNetwork?, completion: @escaping ((EthereumNetwork?) -> Void)) {
        self._selectedNetwork = State(initialValue: selectedNetwork)
        self.completion = completion
    }
    
    @ViewBuilder
    private func list(showsAdaptiveTitle: Bool = false) -> some View {
        List {
#if !os(macOS)
            if showsAdaptiveTitle {
                Text(Strings.selectNetwork)
                    .font(.largeTitle.bold())
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
                    .listRowBackground(Color(uiColor: .systemBackground))
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
            }
#endif
            networkSection(networks: pinned, title: Strings.pinned)
            networkSection(networks: mainnets, title: Strings.mainnets)
            if !custom.isEmpty {
                networkSection(networks: custom, title: Strings.customNetworks)
            }
            networkSection(networks: testnets, title: Strings.testnets)
        }
#if !os(macOS)
        .contentMargins(.top, 0, for: .scrollContent)
#endif
    }
    
    @ViewBuilder
    private func networkSection(networks: [EthereumNetwork], title: String? = nil) -> some View {
        Section(header: title.map { Text($0) }) {
            ForEach(networks, id: \.self) { network in
                HStack {
                    Text(network.name)
                    Spacer()
                    if selectedNetwork?.chainId == network.chainId {
                        Image.checkmark.foregroundStyle(.tint)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
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
