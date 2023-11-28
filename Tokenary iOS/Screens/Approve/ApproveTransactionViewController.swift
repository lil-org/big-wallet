// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import WalletCore
import SwiftUI

class ApproveTransactionViewController: UIViewController {
    
    private enum CellModel {
        case text(text: String, oneLine: Bool, pro: Bool)
        case textWithImage(text: String, extraText: String?, imageURL: String?, image: UIImage?)
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
    private var balance: String?
    
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: Images.preferences, style: .plain, target: self, action: #selector(editTransactionButtonTapped))
        navigationItem.rightBarButtonItem?.tintColor = .tertiaryLabel
        isModalInPresentation = true
        sectionModels = [[]]
        
        updateDisplayedTransactionInfo(initially: true)
        prepareTransaction()
        enableSpeedConfigurationIfNeeded()
        
        ethereum.getBalance(network: chain, address: account.address) { [weak self] balance in
            self?.balance = balance.eth(shortest: true) + " " + (self?.chain.symbol ?? "")
            self?.updateDisplayedTransactionInfo(initially: false)
        }
    }
    
    @objc private func editTransactionButtonTapped() {
        let editTransactionView = EditTransactionView(initialTransaction: transaction) { [weak self] editedTransaction in
            self?.presentedViewController?.dismiss(animated: true)
        }
        let hostingController = UIHostingController(rootView: editTransactionView)
        present(hostingController, animated: true)
    }
    
    private func prepareTransaction() {
        ethereum.prepareTransaction(transaction, network: chain) { [weak self] updated in
            guard updated.id == self?.transaction.id else { return }
            self?.transaction = updated
            self?.updateDisplayedTransactionInfo(initially: false)
            self?.enableSpeedConfigurationIfNeeded()
        }
    }
    
    private func updateDisplayedTransactionInfo(initially: Bool) {
        var cellModels: [CellModel] = [
            .textWithImage(text: peerMeta?.name ?? Strings.unknownWebsite, extraText: nil, imageURL: peerMeta?.iconURLString, image: nil),
            .textWithImage(text: account.croppedAddress, extraText: balance, imageURL: nil, image: account.image),
            .textWithImage(text: chain.name, extraText: nil, imageURL: nil, image: Images.network)
        ]
        
        let price = priceService.forNetwork(chain)
        if let value = transaction.valueWithSymbol(chain: chain, price: price, withLabel: true) {
            cellModels.append(.text(text: value, oneLine: false, pro: false))
        }
        cellModels.append(.text(text: transaction.feeWithSymbol(chain: chain, price: price), oneLine: false, pro: false))
        cellModels.append(.text(text: transaction.gasPriceWithLabel(chain: chain), oneLine: false, pro: false))
        
        if chain.isEthMainnet {
            cellModels.append(.gasPriceSlider)
        }
        
        if let interpretation = transaction.interpretation {
            cellModels.append(.text(text: interpretation, oneLine: false, pro: true))
        } else if let data = transaction.nonEmptyDataWithLabel {
            cellModels.append(.text(text: data, oneLine: false, pro: true))
        }
        
        sectionModels[0] = cellModels
        if !initially, tableView.numberOfSections > 0 {
            tableView.reloadData()
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
