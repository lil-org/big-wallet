// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import WalletConnect

class ApproveViewController: NSViewController {
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var peerNameLabel: NSTextField!
    @IBOutlet weak var peerLogoImageView: NSImageView! {
        didSet {
            peerLogoImageView.wantsLayer = true
            peerLogoImageView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.5).cgColor
        }
    }
    
    private var approveTitle: String!
    private var meta: String!
    private var completion: ((Bool) -> Void)!
    private var peerMeta: WCPeerMeta?
    
    static func with(reason: ApprovalReason, meta: String, peerMeta: WCPeerMeta?, completion: @escaping (Bool) -> Void) -> ApproveViewController {
        let new = instantiate(ApproveViewController.self)
        new.completion = completion
        new.meta = meta
        new.approveTitle = reason.title
        new.peerMeta = peerMeta
        return new
    }
    
    func setMeta(_ meta: String) {
        self.meta = meta
        updateDisplayedMeta()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = approveTitle
        updateDisplayedMeta()
        if let peer = peerMeta {
            peerNameLabel.stringValue = peer.name
            if let urlString = peer.icons.first, let url = URL(string: urlString) {
                peerLogoImageView.kf.setImage(with: url) { [weak peerLogoImageView] result in
                    if case .success = result {
                        peerLogoImageView?.layer?.backgroundColor = NSColor.clear.cgColor
                    }
                }
            }
        }
    }
    
    private func updateDisplayedMeta() {
        metaTextView.string = meta
    }

    @IBAction func actionButtonTapped(_ sender: Any) {
        completion(true)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        completion(false)
    }
    
}
