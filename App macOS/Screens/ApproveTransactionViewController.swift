// ∅ 2026 lil org

import Cocoa

class ApproveTransactionViewController: NSViewController {

    private enum SheetState {
        case idle
        case transactionEditor(NSWindow)
        case endingTransactionEditor(NSWindow, () -> Void)
    }
    
    @IBOutlet weak var infoTextViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var speedContainerStackView: NSStackView!
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var editTransactionButton: NSButton!
    @IBOutlet weak var speedSlider: NSSlider!
    @IBOutlet weak var slowSpeedLabel: NSTextField!
    @IBOutlet weak var fastSpeedLabel: NSTextField!
    @IBOutlet weak var peerNameLabel: NSTextField!
    
    private let ethereum = Ethereum.shared
    private let priceService = PriceService.shared
    private struct ApprovalAttempt {
        let reservation: TransactionApprovalReservation
        let task: Task<Void, Never>
    }

    enum PrimaryAction: Equatable {
        case approve, retry, edit, unavailable

        var title: String {
            switch self {
            case .approve, .unavailable: Strings.ok
            case .retry: Strings.tryAgain
            case .edit: Strings.editFees
            }
        }
    }

    private var approvalAttempt: ApprovalAttempt?
    private var balanceTask: Task<Void, Never>?
    private var priceTask: Task<Void, Never>?
    private var coordinator: TransactionApprovalCoordinator!
    private var approvalSnapshot: TransactionApprovalSnapshot!
    private var chain: EthereumNetwork!
    private var completion: ((Transaction?) -> Void)?
    private var account: WalletAccount!
    private var walletId: String!
    private var balance: String?
    private var displayedGasSliderValue: Double?
    private var gasSliderInteractionStartValue: Double?
    private var gasSliderInteractionDidMove = false
    private var sheetState = SheetState.idle
    private var reviewLifetime: NativeApprovalReviewLifetime!

    private var transaction: Transaction {
        approvalSnapshot.transaction
    }
    
    static func with(transaction: Transaction, chain: EthereumNetwork, account: WalletAccount, walletId: String, reviewLifetime: NativeApprovalReviewLifetime, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self)
        new.walletId = walletId
        new.reviewLifetime = reviewLifetime
        new.account = account
        new.chain = chain
        new.completion = completion
        new.coordinator = TransactionApprovalCoordinator(
            transaction: transaction,
            network: chain
        )
        new.approvalSnapshot = new.coordinator.snapshot
        new.coordinator.onSnapshot = { [weak new] snapshot in
            new?.render(snapshot)
        }
        return new
    }

    func render(_ snapshot: TransactionApprovalSnapshot) {
        guard reviewLifetime.isActive else { return }
        let revealNotice = snapshot.notice != nil && snapshot.notice != approvalSnapshot.notice
        approvalSnapshot = snapshot
        updateInterface(revealNotice: revealNotice)
    }
    
    isolated deinit {
        approvalAttempt?.task.cancel()
        balanceTask?.cancel()
        priceTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reviewLifetime.register(self)
        guard reviewLifetime.isActive else { return }
        
        okButton.title = Strings.ok
        cancelButton.title = Strings.cancel
        
        priceTask = Task { [weak self, priceService] in
            await priceService.update()
            guard let self, !Task.isCancelled, reviewLifetime.isActive else { return }
            updateTextView()
        }
        titleLabel.stringValue = Strings.sendTransaction
        speedSlider.isContinuous = true
        speedSlider.minValue = 0
        speedSlider.maxValue = GasSpeedConfiguration.maximumSliderPosition
        speedSlider.numberOfTickMarks = 3
        speedSlider.allowsTickMarkValuesOnly = false
        speedSlider.setAccessibilityLabel(Strings.priorityFee)
        speedSlider.setAccessibilityHelp(Strings.transactionSpeedHint)
        speedSlider.setAccessibilityIdentifier("transactionSpeedSlider")
        editTransactionButton.setAccessibilityLabel(Strings.editFees)
        editTransactionButton.setAccessibilityIdentifier(
            "editTransactionFeesButton"
        )
        editTransactionButton.toolTip = Strings.editFees
        _ = speedSlider.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        setSpeedConfigurationViews(enabled: false)
        updateInterface()
        coordinator.startPreparation(forceGasCheck: false)
        
        let network = chain!
        let address = account.address
        balanceTask = Task { [weak self, ethereum] in
            guard let balance = try? await ethereum.getBalance(network: network, address: address),
                  let self, !Task.isCancelled, reviewLifetime.isActive else { return }
            self.balance = balance.eth(shortest: true) + " " + network.symbol
            updateTextView()
        }
        
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateRequester()
        view.window?.delegate = self
        view.window?.makeFirstResponder(view)
    }

    private func updateRequester() {
        let peer = nativeApprovalPeer
        peerNameLabel.stringValue = peer?.name ?? ""
        peerNameLabel.superview?.isHidden = peer == nil
    }

    private func startApproval() {
        guard approvalAttempt == nil, reviewLifetime.isActive,
              let window = view.window,
              let reservation = coordinator.reserveForPreflight() else { return }
        let coordinator = coordinator!
        let lifetime = reviewLifetime!
        let task = Task { [weak self, weak window] in
            let succeeded = await Window.authenticate(in: window, reason: .sendTransaction, reviewLifetime: lifetime)
            guard let self, !Task.isCancelled, lifetime.isActive,
                  approvalAttempt?.reservation == reservation else { return }
            defer {
                if approvalAttempt?.reservation == reservation {
                    approvalAttempt = nil
                    updateInterface()
                }
            }
            guard succeeded else {
                coordinator.releaseReservation(reservation)
                return
            }
            let outcome = await coordinator.preflight(reservation)
            guard !Task.isCancelled, lifetime.isActive,
                  approvalAttempt?.reservation == reservation else { return }
            if case .approved(let transaction) = outcome {
                approvalAttempt = nil
                complete(transaction)
            }
        }
        approvalAttempt = ApprovalAttempt(reservation: reservation, task: task)
    }

    private func cancelApproval() {
        let attempt = approvalAttempt
        approvalAttempt = nil
        attempt?.task.cancel()
    }

    private func complete(_ transaction: Transaction?) {
        guard reviewLifetime.isActive, let completion else { return }
        self.completion = nil
        cancelApproval()
        coordinator.invalidate()
        sheetState = .idle
        resetGasSliderInteraction()
        completion(transaction)
    }

    static func primaryAction(for snapshot: TransactionApprovalSnapshot) -> PrimaryAction {
        if snapshot.canApprove { return .approve }
        if snapshot.canRetryPreparation { return .retry }
        if snapshot.notice != nil, snapshot.canEdit { return .edit }
        return .unavailable
    }

    private func endTransactionEditorSheet(
        completion: @escaping () -> Void = {}
    ) {
        guard case let .transactionEditor(editorWindow) = sheetState else {
            completion()
            return
        }

        sheetState = .endingTransactionEditor(editorWindow, completion)
        if let parent = editorWindow.sheetParent { parent.endSheet(editorWindow) }
        else { transactionEditorDidEnd(editorWindow) }
    }

    private func transactionEditorDidEnd(_ editorWindow: NSWindow) {
        guard reviewLifetime.isActive else {
            editorWindow.orderOut(nil)
            return
        }
        let completion: (() -> Void)?
        switch sheetState {
        case .endingTransactionEditor(let current, let afterDismissal) where current === editorWindow:
            completion = afterDismissal
        case .transactionEditor(let current) where current === editorWindow:
            completion = nil
        default:
            editorWindow.orderOut(nil)
            return
        }
        sheetState = .idle
        editorWindow.orderOut(nil)
        completion?()
    }
    
    private func updateInterface(revealNotice: Bool = false) {
        if !chain.isEthMainnet {
            speedContainerStackView.isHidden = true
            infoTextViewBottomConstraint.constant = 30
        }
        
        updateTextView(revealNotice: revealNotice)
        let primaryAction = Self.primaryAction(for: approvalSnapshot)
        okButton.title = primaryAction.title
        okButton.isEnabled = approvalAttempt == nil && primaryAction != .unavailable
        editTransactionButton.isEnabled = approvalAttempt == nil && approvalSnapshot.canEdit
        updateSpeedConfigurationState()
        updateSpeedAccessibilityDetail()
    }

    private var displayedMetaAndBalance = ("", "")
    private lazy var accountImageAttachmentString = NSAttributedString.accountImageAttachment(account: account)
    
    private func updateTextView(revealNotice: Bool = false) {
        let meta = Self.approvalDescription(
            transaction: transaction,
            chain: chain,
            price: priceService.forNetwork(chain),
            notice: approvalSnapshot.notice
        )
        let balanceString = balance ?? ""
        guard displayedMetaAndBalance != (meta, balanceString) else { return }
        displayedMetaAndBalance = (meta, balanceString)
        
        let fullString = NSMutableAttributedString(attributedString: accountImageAttachmentString)
        fullString.insert(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 5)]), at: 0)
        let addressString = NSAttributedString(string: " " + account.nameOrCroppedAddress(walletId: walletId),
                                               attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let balanceAttributedString = NSAttributedString(string: "\n" + balanceString + "\n\n",
                                               attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor])
        let metaString = NSAttributedString(string: meta,
                                            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        fullString.append(addressString)
        fullString.append(balanceAttributedString)
        let noticeStart = fullString.length
        fullString.append(metaString)
        metaTextView.textStorage?.setAttributedString(fullString)
        if revealNotice {
            metaTextView.scrollRangeToVisible(NSRange(location: noticeStart, length: 0))
        }
    }

    static func approvalDescription(
        transaction: Transaction,
        chain: EthereumNetwork,
        price: Double?,
        notice: TransactionReviewNotice? = nil
    ) -> String {
        var result = [String]()
        if let notice {
            result.append([notice.title, notice.message].compactMap { $0 }.joined(separator: "\n"))
        }
        result.append("🌐 " + chain.name)
        if let value = transaction.valueWithSymbol(
            chain: chain,
            price: price,
            withLabel: false
        ) {
            result.append(value)
        }

        result.append(
            contentsOf: transaction.feeSummaryLines(
                chain: chain,
                price: price
            )
        )

        if let interpretation = transaction.diplayDataInterpretation {
            result.append(interpretation)
        }
        return result.joined(separator: "\n\n")
    }
    
    private var isSpeedConfigurationEnabled: Bool {
        guard approvalAttempt == nil, approvalSnapshot.allowsMutation,
              chain.isEthMainnet,
              transaction.feeBasisBaseFeePerGas != nil,
              approvalSnapshot.hasGasSpeedInfo else {
            return false
        }
        guard transaction.preparedFee == nil else { return true }
        if case .automatic = transaction.feeIntent {
            return false
        }
        return true
    }

    private func updateSpeedConfigurationState() {
        guard chain.isEthMainnet else { return }
        let isEnabled = isSpeedConfigurationEnabled
        setSpeedConfigurationViews(enabled: isEnabled)
        if isEnabled {
            updateGasSliderValueIfNeeded()
        }
    }

    private func updateGasSliderValueIfNeeded() {
        guard gasSliderInteractionStartValue == nil,
              isSpeedConfigurationEnabled else { return }
        let sliderValue = approvalSnapshot.gasSliderPosition
        speedSlider.doubleValue = sliderValue
        displayedGasSliderValue = sliderValue
        updateSpeedAccessibilityDetail()
    }

    private func setSpeedConfigurationViews(enabled: Bool) {
        slowSpeedLabel.alphaValue = enabled ? 1 : 0.5
        fastSpeedLabel.alphaValue = enabled ? 1 : 0.5
        speedSlider.isEnabled = enabled
    }

    private func updateSpeedAccessibilityDetail() {
        guard chain.isEthMainnet else { return }
        let detail = !approvalSnapshot.hasGasSpeedInfo
            ? Strings.calculating.withEllipsis
            : speedAccessibilityDetail()
        speedSlider.setAccessibilityValueDescription(detail)
    }

    private func speedAccessibilityDetail() -> String {
        let priority = approvalSnapshot.speedPriorityFeePerGas
        guard let priority else { return Strings.calculating.withEllipsis }
        let fee = "\(priority.compactGwei()) \(Strings.gwei)"
        return Transaction.editableGwei(fromWei: priority).map {
            "\($0) \(Strings.gwei)"
        } ?? fee
    }
    
    @IBAction func editTransactionButtonTapped(_ sender: Any) {
        presentTransactionEditor()
    }

    private func presentTransactionEditor() {
        guard approvalAttempt == nil, let snapshot = approvalSnapshot,
              snapshot.canEdit,
              case .idle = sheetState,
              let window = view.window else {
            return
        }
        let editTransactionView = EditTransactionView(
            initialTransaction: snapshot.transaction,
            chain: chain,
            suggestedNonce:
                snapshot.suggestedNonce ??
                snapshot.transaction.decimalNonceString,
            suggestedFee: snapshot.latestWalletSuggestedFee,
            completion: { [weak self] edits in
                guard let self,
                      reviewLifetime.isActive else { return }
                guard let edits else {
                    self.endTransactionEditorSheet()
                    return
                }
                guard self.approvalSnapshot.canEdit else {
                    self.endTransactionEditorSheet()
                    return
                }
                guard self.coordinator.apply(edits: edits) else {
                    self.endTransactionEditorSheet()
                    return
                }
                self.endTransactionEditorSheet { [weak self] in
                    guard let self, reviewLifetime.isActive,
                          self.approvalSnapshot.phase != .finished else {
                        return
                    }
                    self.updateInterface()
                    self.coordinator.startPreparation(
                        forceGasCheck: true
                    )
                }
            }
        )
        let editWindow = makeHostingWindow(content: editTransactionView)
        let editWindowHeight: CGFloat =
            snapshot.transaction.usesEIP1559Fees ? 260 : 195
        editWindow.setContentSize(
            NSSize(width: 300, height: editWindowHeight)
        )
        sheetState = .transactionEditor(editWindow)
        window.beginSheet(editWindow) { [weak self, weak editWindow] _ in
            guard let self, let editWindow else { return }
            transactionEditorDidEnd(editWindow)
        }
    }
    
    @IBAction func sliderValueChanged(_ sender: NSSlider) {
        guard approvalSnapshot.allowsMutation,
              approvalSnapshot.hasGasSpeedInfo else {
            finishGasSliderInteraction(cancelled: true)
            updateInterface()
            return
        }
        coordinator.beginSliderInteraction()

        let eventType = NSApp.currentEvent?.type
        if eventType == .leftMouseDown {
            let startValue = displayedGasSliderValue ?? sender.doubleValue
            gasSliderInteractionStartValue = startValue
            gasSliderInteractionDidMove =
                abs(sender.doubleValue - startValue) >= 0.001
            if gasSliderInteractionDidMove {
                coordinator.setFeeForSpeed(value: sender.doubleValue)
                updateInterface()
            }
            return
        }

        if eventType == .leftMouseDragged || eventType == .leftMouseUp {
            let startValue = gasSliderInteractionStartValue ?? displayedGasSliderValue ?? sender.doubleValue
            gasSliderInteractionStartValue = startValue
            if abs(sender.doubleValue - startValue) >= 0.001 {
                gasSliderInteractionDidMove = true
            }

            guard gasSliderInteractionDidMove else {
                if eventType == .leftMouseUp {
                    finishGasSliderInteraction(cancelled: false)
                    updateInterface()
                }
                return
            }

            coordinator.setFeeForSpeed(value: sender.doubleValue)
            if eventType == .leftMouseUp {
                finishGasSliderInteraction(
                    cancelled: false
                )
            }
            updateInterface()
            return
        }

        let value = sender.doubleValue
        if let displayedGasSliderValue,
           abs(value - displayedGasSliderValue) < 0.001 {
            sender.doubleValue = displayedGasSliderValue
            finishGasSliderInteraction(
                cancelled: false
            )
            updateInterface()
            return
        }
        coordinator.setFeeForSpeed(value: value)
        finishGasSliderInteraction(
            cancelled: false
        )
        updateInterface()
    }

    private func finishGasSliderInteraction(cancelled: Bool) {
        coordinator.endSliderInteraction(cancelled: cancelled)
        resetGasSliderInteraction()
    }

    private func resetGasSliderInteraction() {
        gasSliderInteractionStartValue = nil
        gasSliderInteractionDidMove = false
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        guard reviewLifetime.isActive, approvalAttempt == nil else { return }
        switch Self.primaryAction(for: approvalSnapshot) {
        case .approve: startApproval()
        case .retry: coordinator.retryPreparation()
        case .edit: presentTransactionEditor()
        case .unavailable: okButton.isEnabled = false
        }
    }

    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        complete(nil)
    }
    
}

extension ApproveTransactionViewController:
    NativeApprovalReviewTeardown {

    func invalidateNativeApprovalReview() {
        balanceTask?.cancel()
        priceTask?.cancel()
        cancelApproval()
        sheetState = .idle
        resetGasSliderInteraction()
        coordinator.onSnapshot = { _ in }
        completion = nil
        coordinator.invalidate()
        endAllSheets()
    }

}

extension ApproveTransactionViewController: NSWindowDelegate {

    func windowDidResignKey(_ notification: Notification) {
        guard reviewLifetime.isActive else { return }
        guard gasSliderInteractionStartValue != nil else { return }
        guard approvalSnapshot.allowsMutation else {
            finishGasSliderInteraction(
                cancelled: true
            )
            updateInterface()
            return
        }
        finishGasSliderInteraction(
            cancelled: false
        )
        updateInterface()
    }

    
}
