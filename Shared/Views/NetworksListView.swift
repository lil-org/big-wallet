// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct NetworksListView: View {
    @State private var searchText: String = ""
    let items: [String] = (1...30).map { String($0) }
    
    @Environment(\.presentationMode) var presentationMode

    var filteredItems: [String] {
        items.filter { $0.contains(searchText) || searchText.isEmpty }
    }

    var body: some View {
        VStack {
            SearchBar(text: $searchText)
            List(filteredItems, id: \.self) { item in
                Text(item)
            }
            
            Divider() // Separate the list from the buttons

            HStack {
                Spacer()
                Button("Cancel") {
                    self.presentationMode.wrappedValue.dismiss()
                }
                .padding()

                Button("OK") {
                    self.presentationMode.wrappedValue.dismiss()
                }
                .padding()
            }
        }
    }
}

struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack {
            TextField("Search ...", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }.padding()
    }
}
