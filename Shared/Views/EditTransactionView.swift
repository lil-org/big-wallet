// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct EditTransactionView: View {
    
    @Environment(\.presentationMode) var presentationMode
    @State private var initialTransaction: Transaction
    @State private var didEdit = true // TODO: tmp for dev
    
    private let completion: ((Transaction?) -> Void)
    
    var body: some View {
        VStack {
            Text("advanced settings")
            HStack {
                Button(Strings.cancel) { completion(nil) }.keyboardShortcut(.cancelAction)
                Button(Strings.ok) { completion(nil) }.keyboardShortcut(.defaultAction)
                    .disabled(!didEdit) // TODO: directly check if there are custom values entered?
            }.frame(height: 36).offset(CGSize(width: 0, height: -6))
        }
    }
    
    init(initialTransaction: Transaction, completion: @escaping ((Transaction?) -> Void)) {
        self._initialTransaction = State(initialValue: initialTransaction)
        self.completion = completion
    }
}
