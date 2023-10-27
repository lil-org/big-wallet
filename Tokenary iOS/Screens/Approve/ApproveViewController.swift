// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import WalletCore

class ApproveViewController: UIViewController {
    
    private enum CellModel {
        case text(String), textWithImage(text: String, imageURL: String?, image: UIImage?)
    }
    
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: MultilineLabelTableViewCell.self)
            tableView.registerReusableCell(type: ImageWithLabelTableViewCell.self)
            let bottomOverlayHeight: CGFloat = 70
            tableView.contentInset.bottom += bottomOverlayHeight
            tableView.verticalScrollIndicatorInsets.bottom += bottomOverlayHeight
        }
    }
    
    private var cellModels = [CellModel]()
    
    private var approveTitle: String!
    private var shouldEnableWaiting = false
    private var account: Account!
    private var meta: String!
    private var completion: ((Bool) -> Void)!
    private var peerMeta: PeerMeta?
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    
    static func with(subject: ApprovalSubject, provider: InpageProvider, account: Account, meta: String, peerMeta: PeerMeta?, completion: @escaping (Bool) -> Void) -> ApproveViewController {
        let new = instantiate(ApproveViewController.self, from: .main)
        new.completion = completion
        new.shouldEnableWaiting = false
        new.account = account
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
        cellModels = [.textWithImage(text: peerMeta?.name ?? Strings.unknownWebsite, imageURL: peerMeta?.iconURLString, image: nil),
                      .textWithImage(text: account.croppedAddress, imageURL: nil, image: account.image),
                      .text(meta)]
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        LocalAuthentication.attempt(reason: approveTitle, presentPasswordAlertFrom: self, passwordReason: approveTitle) { [weak self] success in
            if success {
                self?.enableWaitingIfNeeded()
                self?.completion(true)
            }
        }
    }
    
    @IBAction func cancelButtonTapped(_ sender: Any) {
        completion(false)
    }
    
    private func enableWaitingIfNeeded() {
        guard shouldEnableWaiting else { return }
        okButton.configuration?.showsActivityIndicator = true
        okButton.configuration?.title = ""
        okButton.isEnabled = false
        cancelButton.isEnabled = false
    }
    
}

extension ApproveViewController: UITableViewDelegate {
    
}

extension ApproveViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch cellModels[indexPath.row] {
        case let .text(text):
            let cell = tableView.dequeueReusableCellOfType(MultilineLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, largeFont: false, oneLine: false)
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
