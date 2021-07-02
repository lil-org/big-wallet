// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import WalletConnect

class ApproveViewController: NSViewController {
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    
    var approveTitle: String!
    var meta: String!
    var completion: ((Bool) -> Void)!
    
    static func with(title: String, meta: String, peerMeta: WCPeerMeta?, completion: @escaping (Bool) -> Void) -> ApproveViewController {
        let new = instantiate(ApproveViewController.self)
        new.completion = completion
        new.meta = meta
        new.approveTitle = title
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
