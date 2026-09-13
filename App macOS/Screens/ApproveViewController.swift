// ∅ 2026 lil org

import Cocoa

class ApproveViewController: NSViewController {

    enum Decision {
        case rejected
        case approved(solanaCluster: Solana.Cluster?)
    }

    @IBOutlet weak var buttonsStackView: NSStackView!
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var cancelButton: NSButton!
    @IBOutlet weak var peerNameLabel: NSTextField!
    @IBOutlet weak var peerLogoImageView: NSImageView! {
        didSet {
            peerLogoImageView.wantsLayer = true
            peerLogoImageView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.5).cgColor
            peerLogoImageView.layer?.cornerRadius = 5
        }
    }
    
    private var subject: ApprovalSubject!
    private var approveTitle: String!
    private var meta: String!
    private var account: WalletAccount!
    private var completion: ((Decision) -> Void)!
    private var didCallCompletion = false
    private var walletId: String!
    private var solanaClusterOptions: SolanaClusterOptions?
    private var selectedCluster: Solana.Cluster?
    var localWindowCloseCompletion: (() -> Void)?
    private weak var clusterPopUpButton: NSPopUpButton?
    private var canApprove: Bool {
        return solanaClusterOptions == nil || selectedCluster != nil
    }
    
    static func with(subject: ApprovalSubject,
                     meta: String,
                     account: WalletAccount,
                     walletId: String,
                     solanaClusterOptions: SolanaClusterOptions? = nil,
                     completion: @escaping (Decision) -> Void) -> ApproveViewController {
        let new = instantiate(ApproveViewController.self)
        new.walletId = walletId
        new.completion = completion
        new.subject = subject
        new.meta = meta
        new.account = account
        new.approveTitle = subject.title
        new.solanaClusterOptions = solanaClusterOptions
        new.selectedCluster = solanaClusterOptions?.suggestedCluster
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        okButton.title = Strings.ok
        cancelButton.title = Strings.cancel
        
        titleLabel.stringValue = approveTitle
        updateDisplayedMeta()
        configureSolanaClusterSelectionIfNeeded()
        updateOkButtonState()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        peerLogoImageView.cancelRemoteImageLoad()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        let peer = nativeApprovalPeer
        peerNameLabel.stringValue = peer?.name ?? ""
        peerNameLabel.superview?.isHidden = peer == nil
        if peerLogoImageView.image == nil {
            peerLogoImageView.setRemoteImage(with: peer?.iconURLString) { [weak peerLogoImageView] image in
                guard image != nil else { return }
                peerLogoImageView?.layer?.backgroundColor = NSColor.clear.cgColor
                peerLogoImageView?.layer?.cornerRadius = 0
            }
        }
        view.window?.delegate = self
        view.window?.makeFirstResponder(view)
    }
    
    func enableWaiting() {
        guard subject == .approveTransaction else { return }
        buttonsStackView.isHidden = true
        clusterPopUpButton?.isHidden = true
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        titleLabel.stringValue = Strings.sendingTransaction
    }

    private func configureSolanaClusterSelectionIfNeeded() {
        guard let solanaClusterOptions else { return }

        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        popUpButton.controlSize = .small
        popUpButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        popUpButton.target = self
        popUpButton.action = #selector(solanaClusterSelectionChanged(_:))
        popUpButton.translatesAutoresizingMaskIntoConstraints = false

        popUpButton.addItem(withTitle: Strings.selectNetwork)
        for cluster in solanaClusterOptions.clusters {
            popUpButton.addItem(withTitle: solanaClusterOptions.description(for: cluster))
            popUpButton.lastItem?.representedObject = cluster
        }
        if let selectedCluster,
           let index = solanaClusterOptions.clusters.firstIndex(of: selectedCluster) {
            popUpButton.selectItem(at: index + 1)
        }

        view.addSubview(popUpButton)
        clusterPopUpButton = popUpButton

        var constraints = [
            popUpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            popUpButton.widthAnchor.constraint(equalToConstant: 190),
            popUpButton.bottomAnchor.constraint(equalTo: buttonsStackView.topAnchor, constant: -3),
        ]
        if let scrollView = metaTextView.enclosingScrollView {
            constraints.append(popUpButton.topAnchor.constraint(greaterThanOrEqualTo: scrollView.bottomAnchor, constant: 3))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func solanaClusterSelectionChanged(_ sender: NSPopUpButton) {
        guard solanaClusterOptions != nil else { return }
        selectedCluster = sender.selectedItem?.representedObject as? Solana.Cluster
        updateOkButtonState()
    }

    private func updateOkButtonState() {
        okButton.isEnabled = canApprove
    }
    
    private func updateDisplayedMeta() {
        let fullString = NSMutableAttributedString(attributedString: NSAttributedString.accountImageAttachment(account: account))
        fullString.insert(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 5)]), at: 0)
        let addressString = NSAttributedString(string: " " + account.nameOrCroppedAddress(walletId: walletId) + "\n\n",
                                               attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let metaString = NSAttributedString(string: meta, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        fullString.append(addressString)
        fullString.append(metaString)
        metaTextView.textStorage?.setAttributedString(fullString)
    }
    
    private func callCompletion(result: Decision) {
        if !didCallCompletion {
            didCallCompletion = true
            completion(result)
        }
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        guard canApprove else { return }

        callCompletion(result: .approved(solanaCluster: selectedCluster))
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        callCompletion(result: .rejected)
    }
    
}

extension ApproveViewController: NativeApprovalReviewTeardown {

    func invalidateNativeApprovalReview() {
        didCallCompletion = true
        peerLogoImageView?.cancelRemoteImageLoad()
        localWindowCloseCompletion?()
        localWindowCloseCompletion = nil
    }

}

extension ApproveViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        peerLogoImageView?.cancelRemoteImageLoad()
        localWindowCloseCompletion?()
        localWindowCloseCompletion = nil
    }
    
}
