// ∅ 2026 lil org

import UIKit

class ApproveViewController: UIViewController {
    
    private enum CellModel {
        case text(String)
        case textWithImage(text: String, imageURL: String?, image: UIImage?)
        case cluster
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
    private var account: WalletAccount!
    private var walletId: String!
    private var meta: String!
    private var completion: ((Bool) -> Void)!
    private var peerMeta: PeerMeta?
    private var solanaClusterSelection: SolanaClusterSelection?
    private var canApprove: Bool {
        guard let solanaClusterSelection else { return true }
        return solanaClusterSelection.selectedCluster != nil
    }
    
    @IBOutlet weak var okButton: UIButton!
    @IBOutlet weak var cancelButton: UIButton!
    
    static func with(subject: ApprovalSubject,
                     account: WalletAccount,
                     walletId: String,
                     meta: String,
                     peerMeta: PeerMeta?,
                     solanaClusterSelection: SolanaClusterSelection? = nil,
                     completion: @escaping (Bool) -> Void) -> ApproveViewController {
        let new = instantiate(ApproveViewController.self, from: .main)
        new.walletId = walletId
        new.completion = completion
        new.account = account
        new.meta = meta
        new.approveTitle = subject.title
        new.peerMeta = peerMeta
        new.solanaClusterSelection = solanaClusterSelection
        return new
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        okButton.setTitle(Strings.ok, for: .normal)
        cancelButton.setTitle(Strings.cancel, for: .normal)
        navigationItem.title = approveTitle
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
        tableView.allowsSelection = solanaClusterSelection != nil
        cellModels = [
            .textWithImage(text: peerMeta?.name ?? Strings.unknownWebsite, imageURL: peerMeta?.iconURLString, image: nil),
            .textWithImage(text: account.nameOrCroppedAddress(walletId: walletId), imageURL: nil, image: account.image),
            .text(meta),
        ]
        if solanaClusterSelection != nil {
            cellModels.insert(.cluster, at: 2)
        }
        updateOkButtonState()
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        return screenshotMode ? true : super.prefersHomeIndicatorAutoHidden
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @IBAction func okButtonTapped(_ sender: Any) {
        guard canApprove else { return }

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
        guard solanaClusterSelection != nil else { return }
        tableView.allowsSelection = false
        okButton.configuration?.showsActivityIndicator = true
        okButton.configuration?.title = ""
        okButton.isEnabled = false
        cancelButton.isEnabled = false
    }

    private func updateOkButtonState() {
        okButton.isEnabled = canApprove
    }
    
}

extension ApproveViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .cluster = cellModels[indexPath.row],
              let solanaClusterSelection
        else { return }

        let alert = UIAlertController(title: Strings.selectNetwork, message: nil, preferredStyle: .actionSheet)
        for cluster in solanaClusterSelection.clusters {
            alert.addAction(UIAlertAction(title: cluster.displayName, style: .default) { [weak self] _ in
                solanaClusterSelection.selectedCluster = cluster
                self?.updateOkButtonState()
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            })
        }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))

        if let popover = alert.popoverPresentationController,
           let sourceView = tableView.cellForRow(at: indexPath) {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }

        present(alert, animated: true)
    }

}

extension ApproveViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch cellModels[indexPath.row] {
        case let .text(text):
            let cell = tableView.dequeueReusableCellOfType(MultilineLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, largeFont: false, oneLine: false, pro: false)
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case let .textWithImage(text: text, imageURL: imageURL, image: image):
            let cell = tableView.dequeueReusableCellOfType(ImageWithLabelTableViewCell.self, for: indexPath)
            cell.setup(text: text, extraText: nil, imageURL: imageURL, image: image)
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case .cluster:
            let cell = tableView.dequeueReusableCellOfType(ImageWithLabelTableViewCell.self, for: indexPath)
            cell.setup(text: Strings.selectNetwork,
                       extraText: solanaClusterSelection?.selectedClusterDescription,
                       imageURL: nil,
                       image: Images.network)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        cellModels.count
    }
    
}
