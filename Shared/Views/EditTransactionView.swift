// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct EditTransactionView: View {
    
    @Environment(\.presentationMode) var presentationMode
    @State private var initialTransaction: Transaction
    @State private var didEdit = true // TODO: tmp for dev
    
    @State private var gasPrice: String = ""
    @State private var nonce: String = ""
    @State private var gasPriceErrorMessage: String? = nil
    @State private var nonceErrorMessage: String? = nil
    
    private let completion: ((Transaction?) -> Void)
    
    var body: some View {
        VStack {
            HStack {
                Text("Gas Price")
                TextField("Enter Gas Price", text: $gasPrice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: gasPrice) { _ in validateGasPrice() }
                if let message = gasPriceErrorMessage {
                    Text(message)
                        .foregroundColor(.red)
                }
            }.padding()
            HStack {
                Text("Nonce")
                TextField("Enter Nonce", text: $nonce)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: nonce) { _ in validateNonce() }
                if let message = nonceErrorMessage {
                    Text(message)
                        .foregroundColor(.red)
                }
            }.padding()
            HStack {
                Button(Strings.cancel) { completion(nil) }.keyboardShortcut(.cancelAction)
                Button(Strings.ok) { completion(nil) }.keyboardShortcut(.defaultAction)
                    .disabled(!didEdit) // TODO: directly check if there are custom values entered?
            }.frame(height: 36).offset(CGSize(width: 0, height: -6))
        }
    }
    
    private func validateGasPrice() {
        if gasPrice.isEmpty || !isNumber(gasPrice) {
            gasPriceErrorMessage = "Invalid gas price"
        } else {
            gasPriceErrorMessage = nil
        }
    }
    
    private func validateNonce() {
        if nonce.isEmpty || !isNumber(nonce) {
            nonceErrorMessage = "Invalid nonce"
        } else {
            nonceErrorMessage = nil
        }
    }
    
    private func isNumber(_ string: String) -> Bool {
        return Double(string) != nil
    }
    
    init(initialTransaction: Transaction, completion: @escaping ((Transaction?) -> Void)) {
        self._initialTransaction = State(initialValue: initialTransaction)
        self.completion = completion
    }
}
