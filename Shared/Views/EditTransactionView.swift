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
    
    init(initialTransaction: Transaction, completion: @escaping ((Transaction?) -> Void)) {
        self._initialTransaction = State(initialValue: initialTransaction)
        self.completion = completion
        self._gasPrice = State(initialValue: initialTransaction.gasPriceGwei ?? "")
        self._nonce = State(initialValue: initialTransaction.decimalNonceString ?? "")
    }
    
    var body: some View {
        VStack {
            VStack {
                HStack {
                    Text(Strings.nonce).fontWeight(.medium)
                    Spacer()
                    if let message = nonceErrorMessage {
                        Text(message).foregroundColor(.red)
                    }
                }
                TextField(Strings.customNonce, text: $nonce)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: nonce) { _ in validateNonce() }
            }.padding()
            VStack {
                HStack {
                    Text(Strings.gasPrice).fontWeight(.medium)
                    Spacer()
                    if let message = gasPriceErrorMessage {
                        Text(message).foregroundColor(.red)
                    }
                }
                TextField(Strings.customGasPrice, text: $gasPrice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: gasPrice) { _ in validateGasPrice() }
            }.padding([.horizontal, .bottom])
            HStack {
                Button(Strings.cancel) { completion(nil) }.keyboardShortcut(.cancelAction)
                Button(Strings.ok) { completion(nil) }.keyboardShortcut(.defaultAction)
                    .disabled(!didEdit) // TODO: directly check if there are custom values entered?
            }.frame(height: 36).offset(CGSize(width: 0, height: -6)).padding(.top, 2)
        }
    }
    
    private func validateGasPrice() {
        if gasPrice.isEmpty || !isNumber(gasPrice) {
            gasPriceErrorMessage = "invalid gas price"
        } else {
            gasPriceErrorMessage = nil
        }
    }
    
    private func validateNonce() {
        if nonce.isEmpty || !isNumber(nonce) {
            nonceErrorMessage = "invalid nonce"
        } else {
            nonceErrorMessage = nil
        }
    }
    
    private func isNumber(_ string: String) -> Bool {
        return Double(string) != nil
    }
    
}
