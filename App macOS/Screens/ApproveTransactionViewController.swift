// ∅ 2024 lil org

import Cocoa
import WalletCore
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
    private var account: Account!
    private var balance: String?
    private var suggestedNonceAndGasPrice: (nonce: String?, gasPrice: String?)?
    
    static func with(transaction: Transaction, chain: EthereumNetwork, account: Account, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self)
        new.account = account
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
        prepareTransaction(forceGasCheck: false)
        
        ethereum.getBalance(network: chain, address: account.address) { [weak self] balance in
            self?.balance = balance.eth(shortest: true) + " " + (self?.chain.symbol ?? "")
            self?.updateTextView()
        }
        
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
    
    private func prepareTransaction(forceGasCheck: Bool) {
        ethereum.prepareTransaction(transaction, forceGasCheck: forceGasCheck, network: chain) { [weak self] updated in
            guard updated.id == self?.transaction.id else { return }
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
        updateTextView()
        if didEnableSpeedConfiguration, let gwei = transaction.gasPriceGwei {
            gweiLabel.stringValue = "\(gwei) Gwei" // TODO: to strings
        }
    }
    
    private var displayedMetaAndBalance = ("", "")
    private lazy var accountImageAttachmentString: NSAttributedString = {
        let attachment = NSTextAttachment()
        attachment.image = account.image?.withCornerRadius(7)
        attachment.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        let attachmentString = NSAttributedString(attachment: attachment)
        return attachmentString
    }()
    
    private func updateTextView() {
        let meta = transaction.description(chain: chain, price: priceService.forNetwork(chain))
        let balanceString = balance ?? ""
        guard displayedMetaAndBalance != (meta, balanceString) else { return }
        displayedMetaAndBalance = (meta, balanceString)
        
        let fullString = NSMutableAttributedString(attributedString: accountImageAttachmentString)
        fullString.insert(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 5)]), at: 0)
        let addressString = NSAttributedString(string: " " + account.croppedAddress,
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
    
    private func enableSpeedConfigurationIfNeeded() {
        guard !didEnableSpeedConfiguration else { return }
        let newGasInfo = gasService.currentInfo
        guard transaction.hasFee, let gasInfo = newGasInfo else { return }
        didEnableSpeedConfiguration = true
        currentGasInfo = gasInfo
        updateGasSliderValueIfNeeded()
        setSpeedConfigurationViews(enabled: true)
    }
    
    private func updateGasSliderValueIfNeeded() {
        guard didEnableSpeedConfiguration, let gasInfo = currentGasInfo else { return }
        speedSlider.doubleValue = transaction.currentGasInRelationTo(info: gasInfo)
    }

    private func setSpeedConfigurationViews(enabled: Bool) {
        slowSpeedLabel.alphaValue = enabled ? 1 : 0.5
        fastSpeedLabel.alphaValue = enabled ? 1 : 0.5
        speedSlider.isEnabled = enabled
    }
    
    @IBAction func editTransactionButtonTapped(_ sender: Any) {
        if suggestedNonceAndGasPrice == nil { suggestedNonceAndGasPrice = (transaction.decimalNonceString, transaction.gasPriceGwei) }
        let editTransactionView = EditTransactionView(initialTransaction: transaction,
                                                      suggestedNonce: suggestedNonceAndGasPrice?.nonce,
                                                      suggestedGasPrice: suggestedNonceAndGasPrice?.gasPrice) { [weak self] editedTransaction in
            self?.endAllSheets()
            if let editedTransaction = editedTransaction {
                self?.transaction = editedTransaction
                self?.updateInterface()
                self?.prepareTransaction(forceGasCheck: true)
                self?.updateGasSliderValueIfNeeded()
            }
        }
        let editWindow = makeHostingWindow(content: editTransactionView)
        view.window?.beginSheet(editWindow)
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
        endAllSheets()
    }
    
}
