// ∅ 2026 lil org

import UIKit
import SwiftUI

class ApproveTransactionViewController: UIViewController {
    
    private enum CellModel {
        case text(text: String, oneLine: Bool, pro: Bool)
        case textWithImage(text: String, extraText: String?, imageURL: String?, image: UIImage?)
        case gasPriceSlider
    }
    
    private struct CellLayout {
        let cellModels: [CellModel]
        let feeIndex: Int
        let gasPriceIndex: Int
        let sliderIndex: Int?
    }
    
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: MultilineLabelTableViewCell.self)
            tableView.registerReusableCell(type: ImageWithLabelTableViewCell.self)
            tableView.registerReusableCell(type: GasPriceSliderTableViewCell.self)
            let bottomOverlayHeight: CGFloat = 70
            tableView.contentInset.bottom += bottomOverlayHeight
            tableView.verticalScrollIndicatorInsets.bottom += bottomOverlayHeight
        }
    }
    
    private let gasService = GasService.shared
    private let ethereum = Ethereum.shared
    private let priceService = PriceService.shared
    private var gasSpeedConfiguration = GasSpeedConfiguration()
    private var sectionModels = [[CellModel]]()
    private var cellLayout: CellLayout?
    
    private var walletId: String!
    private var account: WalletAccount!
    private var transaction: Transaction!
    private var chain: EthereumNetwork!
    private var completion: ((Transaction?) -> Void)!
    private var didCallCompletion = false
    private var peerMeta: PeerMeta?
    private var balance: String?
    private var suggestedNonceAndGasPrice: (nonce: String?, gasPrice: String?)?
    private var isGasSliderTracking = false
    private var needsTableReloadAfterGasSliderInteraction = false
    private var gasSliderPreparationRestart =
        TransactionPreparationRestartGate()
    private var preparationState = TransactionPreparationState()
    private var preparationCancellation: EthereumRequestCancellation?
    private var preparationFailureAlert: UIAlertController?
    private var pendingPreparationFailure: (
        attemptID: Int,
        forceGasCheck: Bool
    )?
    private var isPresentingTransactionEditor = false
    private var isDismissingTransactionEditor = false
    private weak var transactionEditorController: UIViewController?
    private var isViewVisible = false
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    
    static func with(transaction: Transaction, chain: EthereumNetwork, account: WalletAccount, walletId: String, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self, from: .main)
        new.walletId = walletId
        new.transaction = transaction
        new.chain = chain
        new.completion = completion
        new.account = account
        new.peerMeta = peerMeta
        return new
    }

    deinit {
        preparationCancellation?.cancel()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        okButton.setTitle(Strings.ok, for: .normal)
        cancelButton.setTitle(Strings.cancel, for: .normal)
        
        priceService.update()
        configureAdaptiveLargeTitle(Strings.sendTransaction, tableView: tableView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: Images.preferences, style: .plain, target: self, action: #selector(editTransactionButtonTapped))
        navigationItem.rightBarButtonItem?.tintColor = .tertiaryLabel
        isModalInPresentation = true
        sectionModels = [[]]

        if chain.isEthMainnet {
            gasService.fetchEstimate(
                endpoint: chain.rpcEndpoint
            ) { [weak self] estimate in
                self?.didFetchGasEstimate(estimate)
            }
        }
        
        updateDisplayedTransactionInfo(initially: true)
        prepareTransaction(forceGasCheck: false)
        updateSpeedConfigurationState()
        
        ethereum.getBalance(network: chain, address: account.address) { [weak self] balance in
            self?.balance = balance.eth(shortest: true) + " " + (self?.chain.symbol ?? "")
            self?.updateDisplayedTransactionInfo(initially: false)
        }
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return screenshotMode ? true : super.prefersHomeIndicatorAutoHidden
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.sendTransaction, tableView: tableView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isViewVisible = true
        presentPendingPreparationFailureIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isViewVisible = false
    }
    
    @objc private func editTransactionButtonTapped() {
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
                    self.dismissTransactionEditor()
                    return
                }
                let gasPriceChanged = edits.gasPrice.map {
                    $0 != self.transaction.gasPriceValue
                } ?? false
                guard self.transaction.apply(edits) else {
                    self.dismissTransactionEditor()
                    return
                }
                if gasPriceChanged {
                    self.gasSpeedConfiguration.commitManualGasPrice(
                        self.transaction.gasPriceWei
                    )
                }
                self.invalidatePreparationForEditing()
                let finishEditing = { [weak self] in
                    guard let self, !self.didCallCompletion else { return }
                    self.updateDisplayedTransactionInfo(initially: false)
                    self.updateSpeedConfigurationState()
                    self.prepareTransaction(forceGasCheck: true)
                }
                self.dismissTransactionEditor(completion: finishEditing)
            }
        )
        let hostingController = UIHostingController(rootView: editTransactionView)
        hostingController.modalPresentationStyle = .popover
#if os(visionOS)
        hostingController.preferredContentSize = CGSize(width: 230, height: 300)
#else
        hostingController.preferredContentSize = CGSize(width: 230, height: 250)
#endif
        if let hostingController = hostingController.popoverPresentationController {
            hostingController.permittedArrowDirections = [.up]
            hostingController.barButtonItem = navigationItem.rightBarButtonItem
            hostingController.delegate = self
        }
        transactionEditorController = hostingController
        isPresentingTransactionEditor = true
        present(hostingController, animated: true) { [weak self] in
            guard let self else { return }
            self.isPresentingTransactionEditor = false
            self.presentPendingPreparationFailureIfNeeded()
        }
    }

    private func dismissTransactionEditor(
        completion: @escaping () -> Void = {}
    ) {
        guard let transactionEditorController else {
            completion()
            presentPendingPreparationFailureIfNeeded()
            return
        }

        isDismissingTransactionEditor = true
        transactionEditorController.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.transactionEditorController = nil
            self.isDismissingTransactionEditor = false
            completion()
            self.presentPendingPreparationFailureIfNeeded()
        }
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
        updateDisplayedTransactionInfo(initially: false)
        updateSpeedConfigurationState()
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
        if !isViewVisible ||
            viewIfLoaded?.window == nil ||
            isPresentingTransactionEditor ||
            isDismissingTransactionEditor {
            pendingPreparationFailure = (
                attemptID: attemptID,
                forceGasCheck: forceGasCheck
            )
            return
        }

        let alert = UIAlertController(
            title: Strings.somethingWentWrong,
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: Strings.tryAgain, style: .default) {
            [weak self, weak alert] _ in
            guard let self,
                  let alert,
                  self.preparationFailureAlert === alert else { return }
            alert.dismiss(animated: true) { [weak self, weak alert] in
                guard let self else { return }
                if self.preparationFailureAlert === alert {
                    self.preparationFailureAlert = nil
                }
                guard self.isCurrentPreparationAttempt(attemptID) else { return }
                self.prepareTransaction(forceGasCheck: forceGasCheck)
            }
        })
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel) {
            [weak self, weak alert] _ in
            guard let self,
                  let alert,
                  self.preparationFailureAlert === alert else { return }
            alert.dismiss(animated: true) { [weak self, weak alert] in
                if self?.preparationFailureAlert === alert {
                    self?.preparationFailureAlert = nil
                }
            }
        })
        preparationFailureAlert = alert
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(alert, animated: true)
    }

    private func presentPendingPreparationFailureIfNeeded() {
        guard !didCallCompletion,
              !isPresentingTransactionEditor,
              !isDismissingTransactionEditor,
              let pendingPreparationFailure else {
            return
        }
        self.pendingPreparationFailure = nil
        showPreparationFailure(
            attemptID: pendingPreparationFailure.attemptID,
            forceGasCheck: pendingPreparationFailure.forceGasCheck
        )
    }
    
    private func makeCellLayout() -> CellLayout {
        var cellModels: [CellModel] = [
            .textWithImage(text: peerMeta?.name ?? Strings.unknownWebsite, extraText: nil, imageURL: peerMeta?.iconURLString, image: nil),
            .textWithImage(text: account.nameOrCroppedAddress(walletId: walletId), extraText: balance, imageURL: nil, image: account.image),
            .textWithImage(text: chain.name, extraText: nil, imageURL: nil, image: Images.network)
        ]
        
        let price = priceService.forNetwork(chain)
        if let value = transaction.valueWithSymbol(chain: chain, price: price, withLabel: true) {
            cellModels.append(.text(text: value, oneLine: false, pro: false))
        }
        
        let feeIndex = cellModels.count
        cellModels.append(.text(text: transaction.feeWithSymbol(chain: chain, price: price), oneLine: false, pro: false))
        
        let gasPriceIndex = cellModels.count
        cellModels.append(.text(text: transaction.gasPriceWithLabel(chain: chain), oneLine: false, pro: false))
        
        let sliderIndex: Int?
        if chain.isEthMainnet {
            sliderIndex = cellModels.count
            cellModels.append(.gasPriceSlider)
        } else {
            sliderIndex = nil
        }
        
        if let diplayDataInterpretation = transaction.diplayDataInterpretation {
            cellModels.append(.text(text: diplayDataInterpretation, oneLine: false, pro: true))
        }
        
        return CellLayout(cellModels: cellModels, feeIndex: feeIndex, gasPriceIndex: gasPriceIndex, sliderIndex: sliderIndex)
    }
    
    private func updateDisplayedTransactionInfo(initially: Bool) {
        if !initially, isGasSliderTracking {
            needsTableReloadAfterGasSliderInteraction = true
            okButton.isEnabled = canApproveTransaction
            return
        }

        let newCellLayout = makeCellLayout()
        cellLayout = newCellLayout
        sectionModels[0] = newCellLayout.cellModels
        if !initially, tableView.numberOfSections > 0 {
            tableView.reloadData()
        }
        okButton.isEnabled = canApproveTransaction
    }

    private var canApproveTransaction: Bool {
        preparationState.canApprove(
            transactionID: transaction.id,
            transactionIsReady: transaction.isReadyForApproval(on: chain)
        )
    }
    
    private func refreshGasPriceRows() {
        guard let cellLayout else { return }
        let price = priceService.forNetwork(chain)
        let feeModel: CellModel = .text(text: transaction.feeWithSymbol(chain: chain, price: price), oneLine: false, pro: false)
        let gasPriceModel: CellModel = .text(text: transaction.gasPriceWithLabel(chain: chain), oneLine: false, pro: false)
        
        sectionModels[0][cellLayout.feeIndex] = feeModel
        sectionModels[0][cellLayout.gasPriceIndex] = gasPriceModel
        
        updateVisibleTextCell(at: cellLayout.feeIndex, with: feeModel)
        updateVisibleTextCell(at: cellLayout.gasPriceIndex, with: gasPriceModel)
        
        if tableView.numberOfSections > 0 {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
        okButton.isEnabled = canApproveTransaction
    }
    
    private func updateVisibleTextCell(at row: Int, with model: CellModel) {
        guard case let .text(text, oneLine, pro) = model,
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? MultilineLabelTableViewCell else { return }
        cell.setup(text: text, largeFont: true, oneLine: oneLine, pro: pro)
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
        updateGasSliderValueIfNeeded()
    }

    private func didFetchGasEstimate(_ estimate: GasService.Estimate) {
        guard gasSpeedConfiguration.applyFetchedEstimate(estimate) else { return }
        updateSpeedConfigurationState()
    }
    
    private func updateGasSliderValueIfNeeded() {
        guard !isGasSliderTracking,
              let sliderIndex = cellLayout?.sliderIndex else { return }
        if let cell = tableView.cellForRow(at: IndexPath(row: sliderIndex, section: 0)) as? GasPriceSliderTableViewCell {
            if isSpeedConfigurationEnabled, let gasInfo = gasSpeedConfiguration.info {
                cell.update(value: transaction.currentGasInRelationTo(info: gasInfo), isEnabled: true)
            } else {
                cell.update(value: nil, isEnabled: false)
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    private func callCompletion(result: Transaction?) {
        guard !didCallCompletion else { return }
        didCallCompletion = true
        preparationCancellation?.cancel()
        preparationCancellation = nil
        preparationState.finish()
        pendingPreparationFailure = nil
        preparationFailureAlert = nil
        completion(result)
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard canApproveTransaction else {
            okButton.isEnabled = false
            return
        }
        view.isUserInteractionEnabled = false
        LocalAuthentication.attempt(reason: Strings.sendTransaction, presentPasswordAlertFrom: self, passwordReason: Strings.sendTransaction) { [weak self] success in
            guard let self, !self.didCallCompletion else { return }
            if success, self.canApproveTransaction {
                self.callCompletion(result: self.transaction)
            } else {
                self.view.isUserInteractionEnabled = true
            }
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        callCompletion(result: nil)
    }
    
}

extension ApproveTransactionViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }
    
}

extension ApproveTransactionViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sectionModels[indexPath.section][indexPath.row] {
        case let .text(text, oneLine, pro):
            let cell = tableView.dequeueReusableCellOfType(MultilineLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, largeFont: true, oneLine: oneLine, pro: pro)
            return cell
        case let .textWithImage(text: text, extraText: extraText, imageURL: imageURL, image: image):
            let cell = tableView.dequeueReusableCellOfType(ImageWithLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, extraText: extraText, imageURL: imageURL, image: image)
            return cell
        case .gasPriceSlider:
            let cell = tableView.dequeueReusableCellOfType(GasPriceSliderTableViewCell.self, for: indexPath)
            var value: Double?
            let isEnabled = isSpeedConfigurationEnabled
            if isEnabled, let gasInfo = gasSpeedConfiguration.info {
                value = transaction.currentGasInRelationTo(info: gasInfo)
            }
            cell.setup(value: value, isEnabled: isEnabled, delegate: self)
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sectionModels[section].count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return sectionModels.count
    }
    
}

extension ApproveTransactionViewController: GasPriceSliderDelegate {

    func sliderInteractionStarted() {
        isGasSliderTracking = true
        gasSpeedConfiguration.markGasSliderInteraction()
    }

    func sliderInteractionEnded() {
        isGasSliderTracking = false
        let shouldPrepare = gasSliderPreparationRestart.consume()
        if needsTableReloadAfterGasSliderInteraction {
            needsTableReloadAfterGasSliderInteraction = false
            updateDisplayedTransactionInfo(initially: false)
        }
        updateGasSliderValueIfNeeded()
        if shouldPrepare {
            prepareTransaction(forceGasCheck: false)
        }
    }
    
    func sliderValueChanged(value: Double) {
        guard let gasInfo = gasSpeedConfiguration.info else { return }
        gasSpeedConfiguration.markGasSliderInteraction()
        let previousGasPrice = transaction.gasPriceValue
        transaction.setGasPrice(value: value, inRelationTo: gasInfo)
        let didChangeGasPrice =
            transaction.gasPriceValue != previousGasPrice
        if didChangeGasPrice {
            gasSpeedConfiguration.markGasSliderGasPriceChange()
            if gasSliderPreparationRestart.recordMutation() {
                invalidatePreparationForEditing()
            }
        }
        refreshGasPriceRows()
        updateGasSliderValueIfNeeded()
        if didChangeGasPrice,
           !isGasSliderTracking,
           gasSliderPreparationRestart.consume() {
            prepareTransaction(forceGasCheck: false)
        }
    }
    
}

extension ApproveTransactionViewController: UIPopoverPresentationControllerDelegate {
    
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }

    func presentationControllerWillDismiss(
        _ presentationController: UIPresentationController
    ) {
        guard presentationController.presentedViewController ===
                transactionEditorController else {
            return
        }
        isDismissingTransactionEditor = true
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        guard isDismissingTransactionEditor else { return }
        transactionEditorController = nil
        isDismissingTransactionEditor = false
        presentPendingPreparationFailureIfNeeded()
    }
    
}
