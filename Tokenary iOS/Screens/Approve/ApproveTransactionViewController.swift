// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import WalletCore

class ApproveTransactionViewController: UIViewController {
    
    private enum CellModel {
        case text(text: String, oneLine: Bool)
        case textWithImage(text: String, imageURL: String?, image: UIImage?)
        case gasPriceSlider
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
    private var currentGasInfo: GasService.Info?
    private var sectionModels = [[CellModel]]()
    private var didEnableSpeedConfiguration = false
    
    private var account: Account!
    private var transaction: Transaction!
    private var chain: EthereumNetwork!
    private var completion: ((Transaction?) -> Void)!
    private var didCallCompletion = false
    private var peerMeta: PeerMeta?
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    
    static func with(transaction: Transaction, chain: EthereumNetwork, account: Account, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self, from: .main)
        new.transaction = transaction
        new.chain = chain
        new.completion = completion
        new.account = account
        new.peerMeta = peerMeta
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        priceService.update()
        navigationItem.title = Strings.sendTransaction
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
        
        if chain.isEthMainnet {
            sectionModels = [[], [.gasPriceSlider]]
        } else {
            sectionModels = [[]]
        }
        
        updateDisplayedTransactionInfo(initially: true)
        prepareTransaction()
        enableSpeedConfigurationIfNeeded()
    }
    
    private func prepareTransaction() {
        ethereum.prepareTransaction(transaction, network: chain) { [weak self] updated in
            self?.transaction = updated
            self?.updateDisplayedTransactionInfo(initially: false)
            self?.enableSpeedConfigurationIfNeeded()
        }
    }
    
    private func updateDisplayedTransactionInfo(initially: Bool) {
        var cellModels: [CellModel] = [
            .textWithImage(text: peerMeta?.name ?? Strings.unknownWebsite, imageURL: peerMeta?.iconURLString, image: nil),
            .textWithImage(text: account.croppedAddress, imageURL: nil, image: account.image),
            .textWithImage(text: chain.name, imageURL: nil, image: Images.network)
        ]
        
        let price = priceService.forNetwork(chain)
        if let value = transaction.valueWithSymbol(chain: chain, price: price, withLabel: true) {
            cellModels.append(.text(text: value, oneLine: false))
        }
        cellModels.append(.text(text: transaction.feeWithSymbol(chain: chain, price: price), oneLine: false))
        cellModels.append(.text(text: transaction.gasPriceWithLabel(chain: chain), oneLine: false))
        if let data = transaction.nonEmptyDataWithLabel {
            cellModels.append(.text(text: data, oneLine: true))
        }
        
        sectionModels[0] = cellModels
        if !initially, tableView.numberOfSections > 0 {
            tableView.reloadSections(IndexSet([0]), with: .none)
        }
        okButton.isEnabled = transaction.hasFee
    }
    
    private func enableSpeedConfigurationIfNeeded() {
        guard !didEnableSpeedConfiguration else { return }
        let newGasInfo = gasService.currentInfo
        guard transaction.hasFee, let gasInfo = newGasInfo else { return }
        didEnableSpeedConfiguration = true
        currentGasInfo = gasInfo
        if let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 1)) as? GasPriceSliderTableViewCell {
            cell.update(value: transaction.currentGasInRelationTo(info: gasInfo), isEnabled: true)
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
        if section == sectionModels.count - 1 {
            return 18
        } else {
            return .leastNormalMagnitude
        }
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }
    
}

extension ApproveTransactionViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sectionModels[indexPath.section][indexPath.row] {
        case let .text(text, oneLine):
            let cell = tableView.dequeueReusableCellOfType(MultilineLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, largeFont: true, oneLine: oneLine)
            return cell
        case let .textWithImage(text: text, imageURL: imageURL, image: image):
            let cell = tableView.dequeueReusableCellOfType(ImageWithLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, imageURL: imageURL, image: image)
            return cell
        case .gasPriceSlider:
            let cell = tableView.dequeueReusableCellOfType(GasPriceSliderTableViewCell.self, for: indexPath)
            var value: Double?
            if didEnableSpeedConfiguration, let gasInfo = currentGasInfo {
                value = transaction.currentGasInRelationTo(info: gasInfo)
            }
            cell.setup(value: value, isEnabled: didEnableSpeedConfiguration, delegate: self)
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
    
    func sliderValueChanged(value: Double) {
        guard let gasInfo = currentGasInfo else { return }
        transaction.setGasPrice(value: value, inRelationTo: gasInfo)
        updateDisplayedTransactionInfo(initially: false)
    }
    
}
