// Copyright © 2023 Tokenary. All rights reserved.

import SwiftUI

struct EditTransactionView: View {
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var transaction: Transaction
    private let initialNonce: String
    private let initialGasPrice: String
    
    @State private var canProceedWithOK = true
    @State private var gasPrice: String = ""
    @State private var nonce: String = ""
    @State private var gasPriceErrorMessage: String? = nil
    @State private var nonceErrorMessage: String? = nil
    
    private let completion: ((Transaction?) -> Void)
    
    init(initialTransaction: Transaction, completion: @escaping ((Transaction?) -> Void)) {
        self._transaction = State(initialValue: initialTransaction)
        self.completion = completion
        self.initialNonce = initialTransaction.decimalNonceString ?? ""
        self.initialGasPrice = initialTransaction.gasPriceGwei ?? ""
        self._gasPrice = State(initialValue: initialGasPrice)
        self._nonce = State(initialValue: initialNonce)
    }
    
    var body: some View {
        VStack {
            VStack {
                HStack {
                    Text(Strings.gasPrice).fontWeight(.medium)
                    Spacer()
                    if let message = gasPriceErrorMessage {
                        Text(message).foregroundColor(.secondary)
                    }
                }
                TextField(Strings.customGasPrice, text: $gasPrice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: gasPrice) { _ in didUpdateGasPrice() }
            }.padding()
            VStack {
                HStack {
                    Text(Strings.nonce).fontWeight(.medium)
                    Spacer()
                    if let message = nonceErrorMessage {
                        Text(message).foregroundColor(.secondary)
                    }
                }
                TextField(Strings.customNonce, text: $nonce)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: nonce) { _ in didUpdateNonce() }
            }.padding([.horizontal, .bottom])
            HStack {
                Button(Strings.cancel) { completion(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                Button(Strings.ok) { completion(transaction) }.keyboardShortcut(.defaultAction).disabled(!canProceedWithOK).buttonStyle(.borderedProminent)
            }.frame(height: 36).offset(CGSize(width: 0, height: -6)).padding(.top, 2).padding(.horizontal)
        }
    }
    
    private func didUpdateGasPrice() {
        if !gasPrice.isEmpty, let gasPriceNumber = Double(gasPrice) {
            transaction.setCustomGasPriceGwei(value: gasPriceNumber)
            canProceedWithOK = true
        } else {
            canProceedWithOK = false
        }
    }
    
    private func didUpdateNonce() {
        if !nonce.isEmpty, let nonceNumber = UInt(nonce) {
            transaction.setCustomNonce(value: nonceNumber)
            canProceedWithOK = true
        } else {
            canProceedWithOK = false
        }
    }
    
}
