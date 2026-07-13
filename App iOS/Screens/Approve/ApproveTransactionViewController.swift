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
            gasService.fetchEstimate(rpcUrl: chain.nodeURLString) { [weak self] estimate in
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
    
    @objc private func editTransactionButtonTapped() {
        if suggestedNonceAndGasPrice == nil {
            suggestedNonceAndGasPrice = (transaction.decimalNonceString, transaction.editableGasPriceGwei)
        }
        let editTransactionView = EditTransactionView(
            initialTransaction: transaction,
            chain: chain,
            suggestedNonce: suggestedNonceAndGasPrice?.nonce,
            suggestedGasPrice: suggestedNonceAndGasPrice?.gasPrice,
            completion: { [weak self] edits in
                guard let self else { return }
                self.presentedViewController?.dismiss(animated: true)
                guard let edits else { return }

                let gasPriceChanged = edits.gasPrice.map { $0 != self.transaction.gasPriceValue } ?? false
                guard self.transaction.apply(edits) else { return }
                if gasPriceChanged {
                    self.gasSpeedConfiguration.commitManualGasPrice(self.transaction.gasPriceWei)
                }
                self.updateDisplayedTransactionInfo(initially: false)
                self.updateSpeedConfigurationState()
                self.prepareTransaction(forceGasCheck: true)
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
        present(hostingController, animated: true)
    }
    
    private func prepareTransaction(forceGasCheck: Bool) {
        ethereum.prepareTransaction(transaction, forceGasCheck: forceGasCheck, network: chain) { [weak self] updated in
            guard let self, updated.id == self.transaction.id else { return }
            self.transaction = self.gasSpeedConfiguration.mergingPreparedTransaction(updated, with: self.transaction)
            self.updateDisplayedTransactionInfo(initially: false)
            self.updateSpeedConfigurationState()
        }
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
        transaction.isReadyForApproval(on: chain)
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
        if !didCallCompletion {
            didCallCompletion = true
            completion(result)
        }
    }
    
    private func didApproveTransaction() {
        
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        view.isUserInteractionEnabled = false
        LocalAuthentication.attempt(reason: Strings.sendTransaction, presentPasswordAlertFrom: self, passwordReason: Strings.sendTransaction) { [weak self] success in
            if success, let transaction = self?.transaction {
                self?.didApproveTransaction()
                self?.callCompletion(result: transaction)
            } else {
                self?.view.isUserInteractionEnabled = true
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
        if needsTableReloadAfterGasSliderInteraction {
            needsTableReloadAfterGasSliderInteraction = false
            updateDisplayedTransactionInfo(initially: false)
        }
        updateGasSliderValueIfNeeded()
    }
    
    func sliderValueChanged(value: Double) {
        guard let gasInfo = gasSpeedConfiguration.info else { return }
        gasSpeedConfiguration.markGasSliderInteraction()
        let previousGasPrice = transaction.gasPriceValue
        transaction.setGasPrice(value: value, inRelationTo: gasInfo)
        if transaction.gasPriceValue != previousGasPrice {
            gasSpeedConfiguration.markGasSliderGasPriceChange()
        }
        refreshGasPriceRows()
        updateGasSliderValueIfNeeded()
    }
    
}

extension ApproveTransactionViewController: UIPopoverPresentationControllerDelegate {
    
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
    
}
