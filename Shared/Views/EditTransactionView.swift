// ∅ 2026 lil org

import SwiftUI

struct EditTransactionView: View {

    private let chain: EthereumNetwork
    private let initialGasPrice: BigUInt?
    private let initialGasPriceWasPresent: Bool
    private let initialGasPriceText: String
    private let initialNonce: UInt?
    private let initialNonceWasPresent: Bool
    private let initialNonceText: String
    private let suggestedNonce: String?
    private let suggestedGasPrice: String?
    private let completion: (Transaction.Edits?) -> Void

    @State private var gasPrice: String
    @State private var nonce: String

    private var gasPriceIsValid: Bool {
        if gasPrice == initialGasPriceText {
            guard initialGasPriceWasPresent else { return true }
            guard let initialGasPrice else { return false }
            return Transaction.isValidGasPrice(initialGasPrice, on: chain)
        }
        guard let gasPrice = Transaction.gasPriceWei(fromGwei: gasPrice) else { return false }
        return Transaction.isValidGasPrice(gasPrice, on: chain)
    }

    private var nonceIsValid: Bool {
        if nonce == initialNonceText {
            return !initialNonceWasPresent || initialNonce != nil
        }
        return UInt(nonce) != nil
    }

    private var canCommit: Bool {
        gasPriceIsValid && nonceIsValid
    }

    init(initialTransaction: Transaction,
         chain: EthereumNetwork,
         suggestedNonce: String?,
         suggestedGasPrice: String?,
         completion: @escaping (Transaction.Edits?) -> Void) {
        let gasPrice = initialTransaction.editableGasPriceGwei ?? ""
        let nonce = initialTransaction.decimalNonceString ?? ""
        self.chain = chain
        self.initialGasPrice = initialTransaction.gasPriceValue
        self.initialGasPriceWasPresent = initialTransaction.gasPrice != nil
        self.initialGasPriceText = gasPrice
        self.initialNonce = initialTransaction.nonce.flatMap(UInt.init(hexString:))
        self.initialNonceWasPresent = initialTransaction.nonce != nil
        self.initialNonceText = nonce
        self.suggestedNonce = suggestedNonce
        self.suggestedGasPrice = suggestedGasPrice
        self.completion = completion
        self._gasPrice = State(initialValue: gasPrice)
        self._nonce = State(initialValue: nonce)
    }

    var body: some View {
        VStack {
            VStack {
                HStack {
                    Text(Strings.gasPrice).fontWeight(.medium)
                    Spacer()
                    if let suggestedGasPrice, suggestedGasPrice != gasPrice {
                        Button(Strings.resetTo + " " + suggestedGasPrice, action: resetGasPrice)
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                    }
                }
                TextField(Strings.customGasPrice, text: $gasPrice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()

            VStack {
                HStack {
                    Text(Strings.nonce).fontWeight(.medium)
                    Spacer()
                    if let suggestedNonce, suggestedNonce != nonce {
                        Button(Strings.resetTo + " " + suggestedNonce, action: resetNonce)
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                    }
                }
                TextField(Strings.customNonce, text: $nonce)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding([.horizontal, .bottom])

            HStack {
                Button(Strings.cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(Strings.ok, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
                    .buttonStyle(.borderedProminent)
            }
            .frame(height: 36)
            .offset(CGSize(width: 0, height: -6))
            .padding(.top, 2)
            .padding(.horizontal)
        }
    }

    private func resetGasPrice() {
        guard let suggestedGasPrice else { return }
        gasPrice = suggestedGasPrice
    }

    private func resetNonce() {
        guard let suggestedNonce else { return }
        nonce = suggestedNonce
    }

    private func cancel() {
        completion(nil)
    }

    private func commit() {
        guard canCommit else { return }

        let gasPriceEdit: BigUInt?
        if gasPrice != initialGasPriceText {
            gasPriceEdit = Transaction.gasPriceWei(fromGwei: gasPrice)
        } else {
            gasPriceEdit = nil
        }

        let nonceEdit: UInt?
        if nonce != initialNonceText {
            nonceEdit = UInt(nonce)
        } else {
            nonceEdit = nil
        }

        completion(Transaction.Edits(gasPrice: gasPriceEdit, nonce: nonceEdit))
    }
}
