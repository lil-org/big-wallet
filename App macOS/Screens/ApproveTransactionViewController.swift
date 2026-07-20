// ∅ 2026 lil org

import Cocoa

class ApproveTransactionViewController: NSViewController {
    
    @IBOutlet weak var infoTextViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var speedContainerStackView: NSStackView!
    @IBOutlet weak var gweiLabel: NSTextField!
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var speedSlider: NSSlider!
    @IBOutlet weak var slowSpeedLabel: NSTextField!
    @IBOutlet weak var fastSpeedLabel: NSTextField!
    @IBOutlet weak var peerNameLabel: NSTextField!
    @IBOutlet weak var peerLogoImageView: NSImageView! {
        didSet {
            peerLogoImageView.wantsLayer = true
            peerLogoImageView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.5).cgColor
            peerLogoImageView.layer?.cornerRadius = 5
        }
    }
    
    private let gasService = GasService.shared
    private let ethereum = Ethereum.shared
    private let priceService = PriceService.shared
    private var gasSpeedConfiguration = GasSpeedConfiguration()
    private var transaction: Transaction!
    private var chain: EthereumNetwork!
    private var completion: ((Transaction?) -> Void)!
    private var didCallCompletion = false
    private var peerMeta: PeerMeta?
    private var account: WalletAccount!
    private var walletId: String!
    private var balance: String?
    private var suggestedNonceAndGasPrice: (nonce: String?, gasPrice: String?)?
    private var displayedGasSliderValue: Double?
    private var gasSliderInteractionStartValue: Double?
    private var gasSliderInteractionDidMove = false
    private var gasSliderPreparationRestart =
        TransactionPreparationRestartGate()
    private var preparationState = TransactionPreparationState()
    private var preparationCancellation: EthereumRequestCancellation?
    private var preparationFailureAlert: NSAlert?
    private var pendingPreparationFailure: (
        attemptID: Int,
        forceGasCheck: Bool
    )?
    private var isEndingTransactionEditorSheet = false
    private var transactionEditorDismissalCompletion: (() -> Void)?
    
    static func with(transaction: Transaction, chain: EthereumNetwork, account: WalletAccount, walletId: String, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self)
        new.walletId = walletId
        new.account = account
        new.chain = chain
        new.transaction = transaction
        new.completion = completion
        new.peerMeta = peerMeta
        return new
    }

    deinit {
        preparationCancellation?.cancel()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        okButton.title = Strings.ok
        cancelButton.title = Strings.cancel
        
        priceService.update { [weak self] in
            self?.updateTextView()
        }
        if chain.isEthMainnet {
            gasService.fetchEstimate(
                endpoint: chain.rpcEndpoint
            ) { [weak self] estimate in
                self?.didFetchGasEstimate(estimate)
            }
        }
        titleLabel.stringValue = Strings.sendTransaction
        speedSlider.isContinuous = true
        _ = speedSlider.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        setSpeedConfigurationViews(enabled: false)
        updateInterface()
        prepareTransaction(forceGasCheck: false)
        
        ethereum.getBalance(network: chain, address: account.address) { [weak self] balance in
            self?.balance = balance.eth(shortest: true) + " " + (self?.chain.symbol ?? "")
            self?.updateTextView()
        }
        
        if let peer = peerMeta {
            peerNameLabel.stringValue = peer.name
            if let urlString = peer.iconURLString, let url = URL(string: urlString) {
                peerLogoImageView.setRemoteImage(with: url) { [weak peerLogoImageView] didLoad in
                    if didLoad {
                        peerLogoImageView?.layer?.backgroundColor = NSColor.clear.cgColor
                        peerLogoImageView?.layer?.cornerRadius = 0
                    }
                }
            }
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        view.window?.makeFirstResponder(view)
        presentPendingPreparationFailureIfNeeded()
    }
    
    private func callCompletion(result: Transaction?) {
        guard !didCallCompletion else { return }
        didCallCompletion = true
        preparationCancellation?.cancel()
        preparationCancellation = nil
        preparationState.finish()
        pendingPreparationFailure = nil
        transactionEditorDismissalCompletion = nil
        isEndingTransactionEditorSheet = false
        preparationFailureAlert = nil
        completion(result)
    }
    
    private func prepareTransaction(forceGasCheck: Bool) {
        guard !didCallCompletion else { return }
        preparationCancellation?.cancel()
        let attemptID = preparationState.beginPreparation(
            for: transaction.id
        )
        pendingPreparationFailure = nil
        okButton.isEnabled = false

        preparationCancellation = ethereum.prepareTransaction(
            transaction,
            forceGasCheck: forceGasCheck,
            network: chain,
            onUpdate: { [weak self] updated in
                guard let self,
                      self.preparationState.isCurrent(
                        attemptID: attemptID,
                        transactionID: updated.id
                      ),
                      updated.id == self.transaction.id else {
                    return
                }
                self.installPreparedUpdate(updated)
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let prepared):
                    guard prepared.id == self.transaction.id,
                          self.preparationState.markReady(
                            attemptID: attemptID,
                            transactionID: prepared.id
                          ) else {
                        return
                    }
                    // RPC changes were installed by onUpdate. A zero-RPC
                    // success is the transaction already on screen.
                    self.okButton.isEnabled = self.canApproveTransaction
                case .failure:
                    guard self.preparationState.markFailed(
                        attemptID: attemptID,
                        transactionID: self.transaction.id
                    ) else {
                        return
                    }
                    self.okButton.isEnabled = false
                    self.showPreparationFailure(
                        attemptID: attemptID,
                        forceGasCheck: forceGasCheck
                    )
                }
            }
        )
    }

    private func isCurrentPreparationAttempt(_ attemptID: Int) -> Bool {
        !didCallCompletion &&
            preparationState.isCurrent(
                attemptID: attemptID,
                transactionID: transaction.id
            )
    }

    private func installPreparedUpdate(_ prepared: Transaction) {
        transaction = gasSpeedConfiguration.mergingPreparedTransaction(
            prepared,
            with: transaction
        )
        updateInterface()
    }

    private func invalidatePreparationForEditing() {
        preparationCancellation?.cancel()
        preparationCancellation = nil
        preparationState.beginEditing(transaction.id)
        pendingPreparationFailure = nil
        okButton.isEnabled = false
    }

    private func showPreparationFailure(
        attemptID: Int,
        forceGasCheck: Bool
    ) {
        guard isCurrentPreparationAttempt(attemptID),
              preparationState.phase == .failed else {
            return
        }
        guard preparationFailureAlert == nil else { return }
        guard !isEndingTransactionEditorSheet,
              var window = view.window else {
            pendingPreparationFailure = (
                attemptID: attemptID,
                forceGasCheck: forceGasCheck
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = Strings.somethingWentWrong
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.tryAgain)
        alert.addButton(withTitle: Strings.cancel)
        preparationFailureAlert = alert

        let handleResponse: (NSApplication.ModalResponse) -> Void = {
            [weak self, weak alert] response in
            guard let self else { return }
            if self.preparationFailureAlert === alert {
                self.preparationFailureAlert = nil
            }
            guard response == .alertFirstButtonReturn,
                  self.isCurrentPreparationAttempt(attemptID) else { return }
            self.prepareTransaction(forceGasCheck: forceGasCheck)
        }

        while let attachedSheet = window.attachedSheet {
            window = attachedSheet
        }
        alert.beginSheetModal(
            for: window,
            completionHandler: handleResponse
        )
    }

    private func presentPendingPreparationFailureIfNeeded() {
        guard !didCallCompletion,
              !isEndingTransactionEditorSheet,
              let pendingPreparationFailure else {
            return
        }
        self.pendingPreparationFailure = nil
        showPreparationFailure(
            attemptID: pendingPreparationFailure.attemptID,
            forceGasCheck: pendingPreparationFailure.forceGasCheck
        )
    }

    private func endTransactionEditorSheet(
        completion: @escaping () -> Void = {}
    ) {
        guard let window = view.window,
              let sheet = window.attachedSheet else {
            completion()
            presentPendingPreparationFailureIfNeeded()
            return
        }

        isEndingTransactionEditorSheet = true
        transactionEditorDismissalCompletion = completion
        window.endSheet(sheet)
    }
    
    private func updateInterface() {
        if !chain.isEthMainnet {
            speedContainerStackView.isHidden = true
            gweiLabel.isHidden = true
            infoTextViewBottomConstraint.constant = 30
        }
        
        okButton.isEnabled = canApproveTransaction
        updateSpeedConfigurationState()
        updateTextView()
        if let gwei = transaction.gasPriceGwei {
            gweiLabel.stringValue = "\(gwei) \(Strings.gwei)"
        } else {
            gweiLabel.stringValue = ""
        }
    }

    private var canApproveTransaction: Bool {
        preparationState.canApprove(
            transactionID: transaction.id,
            transactionIsReady: transaction.isReadyForApproval(on: chain)
        )
    }
    
    private var displayedMetaAndBalance = ("", "")
    private lazy var accountImageAttachmentString = NSAttributedString.accountImageAttachment(account: account)
    
    private func updateTextView() {
        let meta = transaction.description(chain: chain, price: priceService.forNetwork(chain))
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
        fullString.append(metaString)
        metaTextView.textStorage?.setAttributedString(fullString)
    }
    
    private var isSpeedConfigurationEnabled: Bool {
        guard chain.isEthMainnet,
              let gasPrice = transaction.gasPriceWei else { return false }
        return gasPrice > 0 && gasSpeedConfiguration.info != nil
    }

    private func updateSpeedConfigurationState() {
        guard chain.isEthMainnet else { return }
        if let gasPrice = transaction.gasPriceWei, gasPrice > 0 {
            gasSpeedConfiguration.installTransactionFallback(gasPrice: gasPrice)
        }
        let isEnabled = isSpeedConfigurationEnabled
        setSpeedConfigurationViews(enabled: isEnabled)
        if isEnabled {
            updateGasSliderValueIfNeeded()
        }
    }

    private func didFetchGasEstimate(_ estimate: GasService.Estimate) {
        guard gasSpeedConfiguration.applyFetchedEstimate(estimate) else { return }
        updateSpeedConfigurationState()
    }
    
    private func updateGasSliderValueIfNeeded() {
        guard gasSliderInteractionStartValue == nil,
              isSpeedConfigurationEnabled,
              let gasInfo = gasSpeedConfiguration.info else { return }
        let sliderValue = transaction.currentGasInRelationTo(info: gasInfo)
        speedSlider.doubleValue = sliderValue
        displayedGasSliderValue = sliderValue
    }

    private func setSpeedConfigurationViews(enabled: Bool) {
        slowSpeedLabel.alphaValue = enabled ? 1 : 0.5
        fastSpeedLabel.alphaValue = enabled ? 1 : 0.5
        speedSlider.isEnabled = enabled
    }
    
    @IBAction func editTransactionButtonTapped(_ sender: Any) {
        guard !didCallCompletion else { return }
        if suggestedNonceAndGasPrice == nil {
            suggestedNonceAndGasPrice = (transaction.decimalNonceString, transaction.editableGasPriceGwei)
        }
        let editTransactionView = EditTransactionView(
            initialTransaction: transaction,
            chain: chain,
            suggestedNonce: suggestedNonceAndGasPrice?.nonce,
            suggestedGasPrice: suggestedNonceAndGasPrice?.gasPrice,
            completion: { [weak self] edits in
                guard let self, !self.didCallCompletion else { return }
                guard let edits else {
                    self.endTransactionEditorSheet()
                    return
                }
                let gasPriceChanged = edits.gasPrice.map {
                    $0 != self.transaction.gasPriceValue
                } ?? false
                guard self.transaction.apply(edits) else {
                    self.endTransactionEditorSheet()
                    return
                }
                if gasPriceChanged {
                    self.gasSpeedConfiguration.commitManualGasPrice(
                        self.transaction.gasPriceWei
                    )
                }
                self.invalidatePreparationForEditing()
                self.endTransactionEditorSheet { [weak self] in
                    guard let self, !self.didCallCompletion else { return }
                    self.updateInterface()
                    self.prepareTransaction(forceGasCheck: true)
                }
            }
        )
        let editWindow = makeHostingWindow(content: editTransactionView)
        view.window?.beginSheet(editWindow)
    }
    
    @IBAction func sliderValueChanged(_ sender: NSSlider) {
        guard let gasInfo = gasSpeedConfiguration.info else { return }
        gasSpeedConfiguration.markGasSliderInteraction()

        let eventType = NSApp.currentEvent?.type
        if eventType == .leftMouseDown {
            let startValue = displayedGasSliderValue ?? sender.doubleValue
            gasSliderInteractionStartValue = startValue
            gasSliderInteractionDidMove = sender.doubleValue != startValue
            if gasSliderInteractionDidMove {
                applyGasSliderValue(
                    sender.doubleValue,
                    inRelationTo: gasInfo
                )
                updateInterface()
            }
            return
        }

        if eventType == .leftMouseDragged || eventType == .leftMouseUp {
            let startValue = gasSliderInteractionStartValue ?? displayedGasSliderValue ?? sender.doubleValue
            gasSliderInteractionStartValue = startValue
            if sender.doubleValue != startValue {
                gasSliderInteractionDidMove = true
            }

            guard gasSliderInteractionDidMove else {
                if eventType == .leftMouseUp {
                    resetGasSliderInteraction()
                    updateGasSliderValueIfNeeded()
                    startPendingGasSliderPreparationIfNeeded()
                }
                return
            }

            applyGasSliderValue(sender.doubleValue, inRelationTo: gasInfo)
            if eventType == .leftMouseUp {
                resetGasSliderInteraction()
            }
            updateInterface()
            if eventType == .leftMouseUp {
                startPendingGasSliderPreparationIfNeeded()
            }
            return
        }

        resetGasSliderInteraction()
        applyGasSliderValue(sender.doubleValue, inRelationTo: gasInfo)
        updateInterface()
        startPendingGasSliderPreparationIfNeeded()
    }

    private func applyGasSliderValue(
        _ value: Double,
        inRelationTo info: GasService.Info
    ) {
        let previousGasPrice = transaction.gasPriceValue
        transaction.setGasPrice(value: value, inRelationTo: info)
        if transaction.gasPriceValue != previousGasPrice {
            gasSpeedConfiguration.markGasSliderGasPriceChange()
            if gasSliderPreparationRestart.recordMutation() {
                invalidatePreparationForEditing()
            }
        }
    }

    private func resetGasSliderInteraction() {
        gasSliderInteractionStartValue = nil
        gasSliderInteractionDidMove = false
    }

    private func startPendingGasSliderPreparationIfNeeded() {
        guard gasSliderPreparationRestart.consume() else { return }
        prepareTransaction(forceGasCheck: false)
    }
    
    @IBAction func actionButtonTapped(_ sender: Any) {
        guard canApproveTransaction else {
            okButton.isEnabled = false
            return
        }
        callCompletion(result: transaction)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        callCompletion(result: nil)
    }
    
}

extension ApproveTransactionViewController: NSWindowDelegate {

    func windowDidResignKey(_ notification: Notification) {
        guard gasSliderInteractionStartValue != nil else { return }
        resetGasSliderInteraction()
        updateInterface()
        startPendingGasSliderPreparationIfNeeded()
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard isEndingTransactionEditorSheet else {
            presentPendingPreparationFailureIfNeeded()
            return
        }

        isEndingTransactionEditorSheet = false
        let completion = transactionEditorDismissalCompletion
        transactionEditorDismissalCompletion = nil
        completion?()
        presentPendingPreparationFailureIfNeeded()
    }
    
    func windowWillClose(_ notification: Notification) {
        callCompletion(result: nil)
        endAllSheets()
    }
    
}
