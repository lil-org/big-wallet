// ∅ 2026 lil org

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct EditTransactionView: View {

    private static let maximumExactGweiTextLength = 79

    private enum FeeMode: Equatable {
        case legacy
        case eip1559
    }

    private enum EIP1559FeeField {
        case priority
        case cap
    }

    private let chain: EthereumNetwork
    private let feeMode: FeeMode
    private let initialGasPriceText: String
    private let initialMaxPriorityFeeText: String
    private let initialMaxFeeText: String
    private let initialFeeProvenance: TransactionFeeProvenance
    private let initialNonce: BigUInt?
    private let initialNonceWasPresent: Bool
    private let initialNonceText: String
    private let gasLimit: BigUInt?
    private let currentBaseFeePerGas: BigUInt?
    private let nextBaseFeePerGas: BigUInt?
    private let suggestedNonce: String?
    private let suggestedFee: PreparedTransactionFee?
    private let completion: (Transaction.Edits?) -> Void

    @State private var gasPrice: String
    @State private var maxPriorityFee: String
    @State private var maxFee: String
    @State private var nonce: String
    @State private var workingFeeProvenance: TransactionFeeProvenance

    private var feeBasisBaseFeePerGas: BigUInt? {
        nextBaseFeePerGas ?? currentBaseFeePerGas
    }

    private var parsedGasPrice: BigUInt? {
        Self.exactWei(fromGwei: gasPrice)
    }

    private var parsedMaxPriorityFee: BigUInt? {
        Self.exactWei(fromGwei: maxPriorityFee)
    }

    private var parsedMaxFee: BigUInt? {
        Self.exactWei(fromGwei: maxFee)
    }

    private var legacyFeeIsValid: Bool {
        guard let parsedGasPrice else { return false }
        guard Transaction.isValidGasPrice(parsedGasPrice, on: chain) else {
            return false
        }
        guard let feeBasisBaseFeePerGas else { return true }
        return parsedGasPrice >= feeBasisBaseFeePerGas
    }

    private var eip1559FeeIsValid: Bool {
        guard let candidateFee,
              case .eip1559(_, let cap) = candidateFee else {
            return false
        }

        guard let feeBasisBaseFeePerGas else { return true }
        return cap >= feeBasisBaseFeePerGas
    }

    private var nonceIsValid: Bool {
        if nonce == initialNonceText {
            return !initialNonceWasPresent || initialNonce != nil
        }
        return UInt(nonce) != nil
    }

    private var canCommit: Bool {
        let feeIsValid = switch feeMode {
        case .legacy:
            legacyFeeIsValid
        case .eip1559:
            eip1559FeeIsValid
        }
        return feeIsValid &&
            maximumNetworkFeeFitsUInt256 &&
            nonceIsValid
    }

    private var candidateFee: PreparedTransactionFee? {
        switch feeMode {
        case .legacy:
            guard let gasPrice = parsedGasPrice else { return nil }
            let fee = PreparedTransactionFee.legacy(gasPrice: gasPrice)
            return fee.isStructurallyValid ? fee : nil
        case .eip1559:
            guard let priority = parsedMaxPriorityFee,
                  let cap = parsedMaxFee else {
                return nil
            }
            let fee = PreparedTransactionFee.eip1559(
                maxPriorityFeePerGas: priority,
                maxFeePerGas: cap
            )
            return fee.isStructurallyValid ? fee : nil
        }
    }

    private var maximumNetworkFeeFitsUInt256: Bool {
        guard let candidateFee else { return true }
        return candidateFee.maximumNetworkFeeFitsUInt256(gasLimit: gasLimit)
    }

    private var suggestedGasPriceText: String? {
        guard case .legacy(let gasPrice) = suggestedFee else { return nil }
        return Transaction.editableGwei(fromWei: gasPrice)
    }

    private var shouldOfferSuggestedLegacyFee: Bool {
        guard let suggestedGasPriceText else { return false }
        return suggestedGasPriceText != gasPrice ||
            workingFeeProvenance != automaticSuggestedFeeProvenance
    }

    private var suggestedEIP1559Texts: (priority: String, cap: String)? {
        guard case let .eip1559(priority, cap) = suggestedFee,
              let priorityText = Transaction.editableGwei(fromWei: priority),
              let capText = Transaction.editableGwei(fromWei: cap) else {
            return nil
        }
        return (priorityText, capText)
    }

    private var shouldOfferSuggestedEIP1559Fees: Bool {
        guard let suggested = suggestedEIP1559Texts else { return false }
        return suggested.priority != maxPriorityFee ||
            suggested.cap != maxFee ||
            workingFeeProvenance != automaticSuggestedFeeProvenance
    }

    private var automaticSuggestedFeeProvenance:
        TransactionFeeProvenance? {
        suggestedFee.map {
            TransactionFeeProvenance(source: .automatic, for: $0)
        }
    }

    init(
        initialTransaction: Transaction,
        chain: EthereumNetwork,
        suggestedNonce: String?,
        suggestedFee: PreparedTransactionFee?,
        completion: @escaping (Transaction.Edits?) -> Void
    ) {
        let feeMode: FeeMode = initialTransaction.usesEIP1559Fees
            ? .eip1559
            : .legacy
        let gasPrice = initialTransaction.editableGasPriceGwei ?? ""
        let maxPriorityFee = Transaction.editableGwei(
            fromWei: initialTransaction.maxPriorityFeePerGasValue
        ) ?? ""
        let maxFee = Transaction.editableGwei(
            fromWei: initialTransaction.maxFeePerGasValue
        ) ?? ""
        let initialNonce = initialTransaction.nonce.flatMap {
            EthereumQuantity.parseUInt256(
                $0,
                allowPrefixless: true
            )
        }
        let nonce = initialNonce?.description ?? ""

        self.chain = chain
        self.feeMode = feeMode
        self.initialGasPriceText = gasPrice
        self.initialMaxPriorityFeeText = maxPriorityFee
        self.initialMaxFeeText = maxFee
        self.initialFeeProvenance = initialTransaction.feeProvenance
        self.initialNonce = initialNonce
        self.initialNonceWasPresent = initialTransaction.nonce != nil
        self.initialNonceText = nonce
        self.gasLimit = initialTransaction.gasLimitValue
        self.currentBaseFeePerGas = initialTransaction.currentBaseFeePerGas
        self.nextBaseFeePerGas = initialTransaction.nextBaseFeePerGas
        self.suggestedNonce = suggestedNonce
        self.suggestedFee = suggestedFee
        self.completion = completion
        self._gasPrice = State(initialValue: gasPrice)
        self._maxPriorityFee = State(initialValue: maxPriorityFee)
        self._maxFee = State(initialValue: maxFee)
        self._nonce = State(initialValue: nonce)
        self._workingFeeProvenance = State(
            initialValue: initialTransaction.feeProvenance
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    switch feeMode {
                    case .legacy:
                        legacyFeeEditor
                    case .eip1559:
                        eip1559FeeEditor
                    }
                    nonceEditor
                }
                .padding()
            }

            actionButtons
                .frame(minHeight: 44)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .frame(minWidth: feeMode == .eip1559 ? 300 : nil)
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                cancelButton
                applyButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) {
                cancelButton
                applyButton
            }
        }
    }

    private var cancelButton: some View {
        Button(Strings.cancel, action: cancel)
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var applyButton: some View {
        Button(Strings.apply, action: commit)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCommit)
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var legacyFeeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Strings.gasPrice).fontWeight(.medium)
                Spacer()
                if shouldOfferSuggestedLegacyFee {
                    Button(
                        Strings.reset,
                        action: resetGasPrice
                    )
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .disableMacOSFocusEffect()
                }
            }
            TransactionTextField(
                placeholder: Strings.customGasPrice,
                text: manuallyEditedLegacyFeeBinding,
                keyboard: .decimal,
                suffix: nil,
                identifier: "transactionGasPriceField"
            )
        }
    }

    private var eip1559FeeEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Strings.priorityFee).fontWeight(.medium)
                    Spacer()
                    if shouldOfferSuggestedEIP1559Fees {
                        Button(
                            Strings.reset,
                            action: resetEIP1559Fees
                        )
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 7)
                        .disableMacOSFocusEffect()
                        .accessibilityIdentifier(
                            "useSuggestedTransactionFees"
                        )
                    }
                }
                TransactionTextField(
                    placeholder: Strings.customMaxPriorityFee,
                    text: manuallyEditedFeeBinding(
                        $maxPriorityFee,
                        field: .priority
                    ),
                    keyboard: .decimal,
                    suffix: Strings.gwei,
                    identifier: "transactionMaxPriorityFeeField"
                )
            }
            feeField(
                title: Strings.maxFee,
                placeholder: Strings.customMaxFee,
                text: manuallyEditedFeeBinding(
                    $maxFee,
                    field: .cap
                ),
                identifier: "transactionMaxFeeField"
            )
        }
    }

    private func feeField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .fontWeight(.medium)
            TransactionTextField(
                placeholder: placeholder,
                text: text,
                keyboard: .decimal,
                suffix: Strings.gwei,
                identifier: identifier
            )
        }
    }

    private var nonceEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Strings.nonce).fontWeight(.medium)
                Spacer()
                if let suggestedNonce, suggestedNonce != nonce {
                    Button(
                        Strings.resetTo + " " + suggestedNonce,
                        action: resetNonce
                    )
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            TransactionTextField(
                placeholder: Strings.customNonce,
                text: $nonce,
                keyboard: .number,
                suffix: nil,
                identifier: "transactionNonceField"
            )
        }
    }

    private func resetGasPrice() {
        guard let suggestedGasPriceText,
              let automaticSuggestedFeeProvenance else { return }
        gasPrice = suggestedGasPriceText
        workingFeeProvenance = automaticSuggestedFeeProvenance
    }

    private func resetEIP1559Fees() {
        guard let suggested = suggestedEIP1559Texts,
              let automaticSuggestedFeeProvenance else { return }
        maxPriorityFee = suggested.priority
        maxFee = suggested.cap
        workingFeeProvenance = automaticSuggestedFeeProvenance
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

        let feeChanged: Bool
        switch feeMode {
        case .legacy:
            feeChanged = gasPrice != initialGasPriceText
        case .eip1559:
            feeChanged =
                maxPriorityFee != initialMaxPriorityFeeText ||
                maxFee != initialMaxFeeText
        }

        let nonceEdit = nonce == initialNonceText ? nil : UInt(nonce)
        let provenanceChanged =
            workingFeeProvenance != initialFeeProvenance
        guard (feeChanged || provenanceChanged),
              let candidateFee else {
            completion(Transaction.Edits(nonce: nonceEdit))
            return
        }

        completion(
            Transaction.Edits(
                preparedFee: candidateFee,
                source: workingFeeProvenance.dominantSource(
                    for: candidateFee
                ),
                replacementFeeProvenance: workingFeeProvenance,
                restoresSuggestedFee:
                    candidateFee == suggestedFee &&
                    workingFeeProvenance ==
                        automaticSuggestedFeeProvenance,
                nonce: nonceEdit
            )
        )
    }

    private func manuallyEditedFeeBinding(
        _ binding: Binding<String>,
        field: EIP1559FeeField
    ) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                if workingFeeProvenance.maxPriorityFeePerGas == .slider ||
                    workingFeeProvenance.maxFeePerGas == .slider {
                    workingFeeProvenance =
                        TransactionFeeProvenance(
                            maxPriorityFeePerGas: .manual,
                            maxFeePerGas: .manual
                        )
                } else {
                    switch field {
                    case .priority:
                        workingFeeProvenance.maxPriorityFeePerGas =
                            .manual
                    case .cap:
                        workingFeeProvenance.maxFeePerGas = .manual
                    }
                }
                binding.wrappedValue = value
            }
        )
    }

    private var manuallyEditedLegacyFeeBinding: Binding<String> {
        Binding(
            get: { gasPrice },
            set: { value in
                workingFeeProvenance =
                    TransactionFeeProvenance(gasPrice: .manual)
                gasPrice = value
            }
        )
    }

    private static func exactWei(fromGwei rawText: String) -> BigUInt? {
        let text = rawText.replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty,
              text.utf8.count <= maximumExactGweiTextLength else {
            return nil
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              parts.allSatisfy({ part in
                  part.unicodeScalars.allSatisfy {
                      (48...57).contains($0.value)
                  }
              }),
              parts.contains(where: { !$0.isEmpty }),
              parts.count < 2 || parts[1].count <= 9 else {
            return nil
        }
        return Transaction.feeWei(fromGwei: text)
    }

}

private enum TransactionTextFieldKeyboard {
    case decimal
    case number
}

private struct TransactionTextField: View {

    let placeholder: String
    @Binding var text: String
    let keyboard: TransactionTextFieldKeyboard
    let suffix: String?
    let identifier: String
    @State private var focusRequest = 0
    @FocusState private var isFocused: Bool

    private var accessibilityLabel: String {
        suffix.map { "\(placeholder), \($0)" } ?? placeholder
    }

    private var outlineColor: Color {
#if os(macOS)
        Color(nsColor: .separatorColor)
#elseif canImport(UIKit)
        Color(uiColor: .separator)
#else
        Color.secondary.opacity(0.15)
#endif
    }

    var body: some View {
        HStack(spacing: 6) {
            input
                .textFieldStyle(.plain)
                .frame(minWidth: 0)
                .accessibilityLabel(
                    Text(verbatim: accessibilityLabel)
                )
                .accessibilityIdentifier(identifier)
            if let suffix {
                Text(suffix)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: requestFocus)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 7)
        .transactionTextFieldVerticalPadding()
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.clear)
                .contentShape(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .onTapGesture(perform: requestFocus)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(outlineColor, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var input: some View {
#if os(macOS)
        MacTransactionTextField(
            placeholder: placeholder,
            text: $text,
            focusRequest: focusRequest
        )
#else
        TextField(placeholder, text: $text)
            .transactionInputKeyboard(keyboard)
            .focused($isFocused)
#endif
    }

    private func requestFocus() {
#if os(macOS)
        focusRequest &+= 1
#else
        isFocused = true
#endif
    }
}

#if os(macOS)
private struct MacTransactionTextField: NSViewRepresentable {

    let placeholder: String
    @Binding var text: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> NonAutoSelectingTextField {
        let textField = NonAutoSelectingTextField()
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(
        _ textField: NonAutoSelectingTextField,
        context: Context
    ) {
        context.coordinator.text = $text
        textField.placeholderString = placeholder
        if textField.stringValue != text {
            textField.stringValue = text
        }
        context.coordinator.handleFocusRequest(
            focusRequest,
            textField: textField
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {

        var text: Binding<String>
        private var lastFocusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.lastFocusRequest = focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = textField.stringValue
        }

        func handleFocusRequest(
            _ focusRequest: Int,
            textField: NonAutoSelectingTextField
        ) {
            guard focusRequest != lastFocusRequest else { return }
            lastFocusRequest = focusRequest
            textField.focusWithoutSelecting()
        }
    }
}

private final class NonAutoSelectingTextField: NSTextField {

    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        moveInsertionPointToEnd()
    }

    func focusWithoutSelecting() {
        window?.makeFirstResponder(self)
        moveInsertionPointToEnd()
    }

    private func moveInsertionPointToEnd() {
        guard let editor = currentEditor() else { return }
        editor.selectedRange = NSRange(
            location: editor.string.utf16.count,
            length: 0
        )
    }
}
#endif

private extension View {

    func disableMacOSFocusEffect() -> some View {
#if os(macOS)
        return focusEffectDisabled()
#else
        return self
#endif
    }

    func transactionInputKeyboard(
        _ keyboard: TransactionTextFieldKeyboard
    ) -> some View {
#if canImport(UIKit)
        switch keyboard {
        case .decimal:
            return keyboardType(.decimalPad)
        case .number:
            return keyboardType(.numberPad)
        }
#else
        return self
#endif
    }

    func transactionTextFieldVerticalPadding() -> some View {
#if os(macOS)
        return padding(.vertical, 3)
#else
        return padding(.vertical, 7)
#endif
    }

}
