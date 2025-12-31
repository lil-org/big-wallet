// ∅ 2026 lil org

import SwiftUI

struct EditTransactionView: View {
    
    @State private var transaction: Transaction
    @State private var canProceedWithOK = true
    @State private var gasPrice: String = ""
    @State private var nonce: String = ""
    
    private let suggestedNonce: String?
    private let suggestedGasPrice: String?
    private let completion: ((Transaction?) -> Void)
    
    init(initialTransaction: Transaction, suggestedNonce: String?, suggestedGasPrice: String?, completion: @escaping ((Transaction?) -> Void)) {
        self._transaction = State(initialValue: initialTransaction)
        self.completion = completion
        self.suggestedNonce = suggestedNonce
        self.suggestedGasPrice = suggestedGasPrice
        self._gasPrice = State(initialValue: initialTransaction.gasPriceGwei ?? "")
        self._nonce = State(initialValue: initialTransaction.decimalNonceString ?? "")
    }
    
    var body: some View {
        VStack {
            VStack {
                HStack {
                    Text(Strings.gasPrice).fontWeight(.medium)
                    Spacer()
                    if let suggestedGasPrice = suggestedGasPrice, suggestedGasPrice != gasPrice {
                        Button(Strings.resetTo + " " + suggestedGasPrice) {
                            gasPrice = suggestedGasPrice
                        }.buttonStyle(.plain).foregroundColor(.secondary)
                    }
                }
                TextField(Strings.customGasPrice, text: $gasPrice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: gasPrice) { _, _ in
                        didUpdateGasPrice()
                    }
            }.padding()
            VStack {
                HStack {
                    Text(Strings.nonce).fontWeight(.medium)
                    Spacer()
                    if let suggestedNonce = suggestedNonce, suggestedNonce != nonce {
                        Button(Strings.resetTo + " " + suggestedNonce) {
                            nonce = suggestedNonce
                        }.buttonStyle(.plain).foregroundColor(.secondary)
                    }
                }
                TextField(Strings.customNonce, text: $nonce)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: nonce) { _, _ in didUpdateNonce() }
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
