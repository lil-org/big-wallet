// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ApproveTransactionViewController: NSViewController {
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var speedSlider: NSSlider!
    @IBOutlet weak var slowSpeedLabel: NSTextField!
    @IBOutlet weak var fastSpeedLabel: NSTextField!
    
    private var transaction: Transaction!
    private var completion: ((Transaction?) -> Void)!
    
    static func with(transaction: Transaction, completion: @escaping (Transaction?) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self)
        new.transaction = transaction
        new.completion = completion
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.stringValue = Strings.sendTransaction
        updateInterface()
        prepareTransaction()
    }
    
    private func prepareTransaction() {
        Ethereum.prepareTransaction(transaction) { [weak self] updated in
            self?.transaction = updated
            self?.updateInterface()
        }
    }
    
    private func updateInterface() {
        let meta = transaction.meta
        if metaTextView.string != meta {
            metaTextView.string = meta
        }
        enableSpeedConfiguration(transaction.hasFee)
    }
    
    private func enableSpeedConfiguration(_ enable: Bool) {
        slowSpeedLabel.alphaValue = enable ? 1 : 0.5
        fastSpeedLabel.alphaValue = enable ? 1 : 0.5
        speedSlider.isEnabled = enable
    }

    @IBAction func sliderValueChanged(_ sender: NSSlider) {
        print(sender.intValue)
    }
    
    @IBAction func actionButtonTapped(_ sender: Any) {
        completion(transaction)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        completion(nil)
    }
    
}
