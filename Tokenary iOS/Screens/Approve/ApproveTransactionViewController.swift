// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import BlockiesSwift

class ApproveTransactionViewController: UIViewController {
    
    private enum CellModel {
        case text(text: String, oneLine: Bool)
        case textWithImage(text: String, imageURL: String?, image: UIImage?)
    }
    
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: MultilineLabelTableViewCell.self)
            tableView.registerReusableCell(type: ImageWithLabelTableViewCell.self)
            tableView.contentInset.bottom = 20
        }
    }
    
    private let gasService = GasService.shared
    private let ethereum = Ethereum.shared
    private let priceService = PriceService.shared
    private var currentGasInfo: GasService.Info?
    private var cellModels = [CellModel]()
    
    private var address: String!
    private var transaction: Transaction!
    private var chain: EthereumChain!
    private var completion: ((Transaction?) -> Void)!
    private var peerMeta: PeerMeta?
    
    @IBOutlet weak var okButton: UIButton!
    
    static func with(transaction: Transaction, chain: EthereumChain, address: String, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self, from: .main)
        new.transaction = transaction
        new.chain = chain
        new.completion = completion
        new.address = address
        new.peerMeta = peerMeta
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = Strings.sendTransaction
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
        updateInterface()
        prepareTransaction()
    }
    
    private func prepareTransaction() {
        ethereum.prepareTransaction(transaction, chain: chain) { [weak self] updated in
            self?.transaction = updated
            self?.updateInterface()
        }
    }
    
    private func updateInterface() {
        cellModels = [
            .textWithImage(text: peerMeta?.name ?? Strings.unknownWebsite, imageURL: peerMeta?.iconURLString, image: nil),
            .textWithImage(text: address.trimmedAddress, imageURL: nil, image: Blockies(seed: address.lowercased()).createImage())
        ]
        
        if let value = transaction.valueWithSymbol(chain: chain, ethPrice: priceService.currentPrice, withLabel: true) {
            cellModels.append(.text(text: value, oneLine: false))
        }
        cellModels.append(.text(text: transaction.feeWithSymbol(chain: chain, ethPrice: priceService.currentPrice), oneLine: false))
        if let data = transaction.nonEmptyDataWithLabel {
            cellModels.append(.text(text: data, oneLine: true))
        }
        
        tableView.reloadData()
        okButton.isEnabled = transaction.hasFee
        
        if chain != .ethereum {
            // TODO: hide fee configuration
        }

//        if didEnableSpeedConfiguration, let gwei = transaction.gasPriceGwei {
//            gweiLabel.stringValue = "\(gwei) Gwei"
//        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        // TODO: ask face id
        completion(transaction)
        dismissAnimated()
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        completion(nil)
        dismissAnimated()
    }
    
}

extension ApproveTransactionViewController: UITableViewDelegate {
    
}

extension ApproveTransactionViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch cellModels[indexPath.row] {
        case let .text(text, oneLine):
            let cell = tableView.dequeueReusableCellOfType(MultilineLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, largeFont: true, oneLine: oneLine)
            return cell
        case let .textWithImage(text: text, imageURL: imageURL, image: image):
            let cell = tableView.dequeueReusableCellOfType(ImageWithLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, imageURL: imageURL, image: image)
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        cellModels.count
    }
    
}
