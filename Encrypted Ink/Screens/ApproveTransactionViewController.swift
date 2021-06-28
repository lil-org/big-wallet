// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class ApproveTransactionViewController: NSViewController {
    
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet var metaTextView: NSTextView!
    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var speedSlider: NSSlider!
    @IBOutlet weak var slowSpeedLabel: NSTextField!
    @IBOutlet weak var fastSpeedLabel: NSTextField!
    
    var approveTitle: String!
    var meta: String!
    var completion: ((Bool) -> Void)!
    
    static func with(title: String, meta: String, completion: @escaping (Bool) -> Void) -> ApproveTransactionViewController {
        let new = instantiate(ApproveTransactionViewController.self)
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
        enableSpeedConfiguration(false)
    }
    
    private func enableSpeedConfiguration(_ enable: Bool) {
        slowSpeedLabel.alphaValue = enable ? 1 : 0.5
        fastSpeedLabel.alphaValue = enable ? 1 : 0.5
        speedSlider.isEnabled = enable
    }
    
    private func updateDisplayedMeta() {
        metaTextView.string = meta
    }

    @IBAction func sliderValueChanged(_ sender: NSSlider) {
        print(sender.intValue)
    }
    
    @IBAction func actionButtonTapped(_ sender: Any) {
        completion(true)
    }
    
    @IBAction func cancelButtonTapped(_ sender: NSButton) {
        completion(false)
    }
    
}
