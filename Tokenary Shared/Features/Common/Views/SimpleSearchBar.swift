// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct SimpleSearchBar: View {
    @Binding
    var text: String
 
    @State
    private var isEditing = false
    
    var body: some View {
        HStack {
            TextField("Search".withEllipsis, text: $text) { editingChanged in
                if editingChanged {
                    withAnimation {
                        self.isEditing = true
                    }
                }
            }
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .padding(7) // basic size accommodation
            .padding(.horizontal, 25) // overlay icons
            .background(Color(light: Color.systemGray6, dark: Color.systemGray6))
            .cornerRadius(8)
            .overlay(
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(Color.systemGray)
                        .frame(minWidth: .zero, alignment: .leading)
                        .padding(.leading, 8)
                    Spacer()
                    if self.isEditing && self.text != .empty {
                        
                        Button(
                            action: {
                                self.isEditing = false
                                self.text = .empty
#if canImport(UIKit)
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                                )
#elseif canImport(AppKit)
                                NSApp.keyWindow?.makeFirstResponder(nil)
#endif
                            }, label: {
                                Image(systemName: "multiply.circle.fill")
                                    .foregroundColor(Color.systemGray)
                                    .padding(.trailing, 8)
                            }
                        )
                        .buttonStyle(.borderless)
                    }
                }
            )
        #if canImport(UIKit)
            .autocapitalization(.none)
        #endif
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
