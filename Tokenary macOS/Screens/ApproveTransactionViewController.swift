// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
import Kingfisher

class ApproveTransactionViewController: NSViewController {
    
    @IBOutlet weak var infoTextViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var speedContainerStackView: NSStackView!
    @IBOutlet weak var gweiLabel: NSTextField!
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
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
    private var currentGasInfo: GasService.Info?
    private var transaction: Transaction!
    private var chain: EthereumNetwork!
    private var completion: ((Transaction?) -> Void)!
    private var didCallCompletion = false
    private var didEnableSpeedConfiguration = false
    private var peerMeta: PeerMeta?
    
    static func with(transaction: Transaction, chain: EthereumNetwork, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self)
        new.chain = chain
        new.transaction = transaction
        new.completion = completion
        new.peerMeta = peerMeta
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        priceService.update()
        titleLabel.stringValue = Strings.sendTransaction
        setSpeedConfigurationViews(enabled: false)
        updateInterface()
        prepareTransaction()
        if let peer = peerMeta {
            peerNameLabel.stringValue = peer.name
            if let urlString = peer.iconURLString, let url = URL(string: urlString) {
                peerLogoImageView.kf.setImage(with: url) { [weak peerLogoImageView] result in
                    if case .success = result {
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
    }
    
    private func callCompletion(result: Transaction?) {
        if !didCallCompletion {
            didCallCompletion = true
            completion(result)
        }
    }
    
    private func prepareTransaction() {
        ethereum.prepareTransaction(transaction, network: chain) { [weak self] updated in
            self?.transaction = updated
            self?.updateInterface()
        }
    }
    
    private func updateInterface() {
        if !chain.isEthMainnet {
            speedContainerStackView.isHidden = true
            gweiLabel.isHidden = true
            infoTextViewBottomConstraint.constant = 30
        }
        
        okButton.isEnabled = transaction.hasFee
        
        enableSpeedConfigurationIfNeeded()
        let meta = transaction.description(chain: chain, price: priceService.forNetwork(chain))
        if metaTextView.string != meta {
            metaTextView.string = meta
        }
        if didEnableSpeedConfiguration, let gwei = transaction.gasPriceGwei {
            gweiLabel.stringValue = "\(gwei) Gwei"
        }
    }
    
    private func enableSpeedConfigurationIfNeeded() {
        guard !didEnableSpeedConfiguration else { return }
        let newGasInfo = gasService.currentInfo
        guard transaction.hasFee, let gasInfo = newGasInfo else { return }
        didEnableSpeedConfiguration = true
        currentGasInfo = gasInfo
        speedSlider.doubleValue = transaction.currentGasInRelationTo(info: gasInfo)
        setSpeedConfigurationViews(enabled: true)
    }

    private func setSpeedConfigurationViews(enabled: Bool) {
        slowSpeedLabel.alphaValue = enabled ? 1 : 0.5
        fastSpeedLabel.alphaValue = enabled ? 1 : 0.5
        speedSlider.isEnabled = enabled
    }
    
    @IBAction func sliderValueChanged(_ sender: NSSlider) {
        guard let gasInfo = currentGasInfo else { return }
        transaction.setGasPrice(value: sender.doubleValue, inRelationTo: gasInfo)
        updateInterface()
    }
    
    @IBAction func actionButtonTapped(_ sender: Any) {
        callCompletion(result: transaction)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        callCompletion(result: nil)
    }
    
}

extension ApproveTransactionViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        callCompletion(result: nil)
    }
    
}
