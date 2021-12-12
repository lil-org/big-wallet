// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

class ApproveViewController: UIViewController {
    
    private var approveTitle: String!
    private var meta: String!
    private var completion: ((Bool) -> Void)!
    private var peerMeta: PeerMeta?
    
    @IBOutlet weak var okButton: UIButton!
    
    static func with(subject: ApprovalSubject, meta: String, peerMeta: PeerMeta?, completion: @escaping (Bool) -> Void) -> ApproveViewController {
        let new = instantiate(ApproveViewController.self, from: .main)
        new.completion = completion
        new.meta = meta
        new.approveTitle = subject.title
        new.peerMeta = peerMeta
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = approveTitle
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        // TODO: ask face id
        completion(true)
        dismissAnimated()
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        completion(false)
        dismissAnimated()
    }
    
}
