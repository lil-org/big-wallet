// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct SimpleSearchBar: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Binding
    var text: String
 
    @State
    private var isEditing = false
    
    var body: some View {
        HStack {
            TextField("Search".withEllipsis, text: $text)
                .padding(7)
                .padding(.horizontal, 25)
                .background(self.colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .frame(minWidth: .zero, maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                    
                        if self.isEditing && self.text != .empty {
                            Button(
                                action: {
                                    self.isEditing = false
                                    self.text = .empty
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                                    )
                                }, label: {
                                    Image(systemName: "multiply.circle.fill")
                                        .foregroundColor(.gray)
                                        .padding(.trailing, 8)
                                }
                            )
                        }
                    }
                )
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.horizontal, 10)
                .onTapGesture {
                    withAnimation {
                        self.isEditing = true
                    }
                }
        }
    }
}
