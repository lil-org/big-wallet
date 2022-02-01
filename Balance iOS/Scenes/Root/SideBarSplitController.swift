import UIKit
import SparrowKit
import SPDiffable
import Constants
import SPAlert

class SideBarSplitController: UISplitViewController {
    
    init() {
        super.init(style: .doubleColumn)
        
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        presentsWithGesture = false
        
        let sideBarController = SidebarController()
        setViewController(sideBarController.wrapToNavigationController(prefersLargeTitles: true), for: .primary)
        
        if let bar = Navigation.sideBars.first?.rows.first {
            setViewController(bar.getController(), for: .secondary)
        }
        
        if UIDevice.current.isMac {
            preferredPrimaryColumnWidth = Layout.Sizes.Controller.split_side_bar_preferred_width
        }
        
        setViewController(TabBarController(), for: .compact)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(processInput), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if Flags.seen_tutorial && Keychain.shared.hasPassword {
            AuthService.auth(cancelble: false, on: self) { success in }
        } else {
            Presenter.App.showOnboarding(on: self, afterAction: {
                Presenter.Crypto.showWalletOnboarding(on: self)
                Flags.seen_tutorial = true
            })
        }
    }
    
    // MARK: - Extension Logic
    
    @objc private func processInput() {
        let prefix = "balance://"
        guard let url = launchURL?.absoluteString, url.hasPrefix(prefix),
              let request = SafariRequest(query: String(url.dropFirst(prefix.count))) else { return }
        launchURL = nil
        
        guard ExtensionBridge.hasRequest(id: request.id) else {
            SPAlert.present(message: "This operation will support later", haptic: .warning, completion: nil)
            return
        }
        
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.iconURLString)
        
        switch request.method {
        case .switchAccount, .requestAccounts:
            Presenter.Crypto.Extension.showLinkWallet(didSelectWallet: { wallet, chain, controller  in
                guard let address = wallet.ethereumAddress else {
                    self.showErrorAlert()
                    return
                }
                let response = ResponseToExtension(id: request.id, name: request.name, results: [address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                self.respondTo(request: request, response: response, on: controller)
            }, on: self)
        case .signTransaction:
            guard let transaction = request.transaction, let chain = request.chain, let wallet = WalletsManager.shared.getWallet(address: request.address), let address = wallet.ethereumAddress else {
                self.showErrorAlert()
                return
            }
            Presenter.Crypto.Extension.showApproveSendTransaction(
                transaction: transaction,
                chain: chain,
                address: address,
                peerMeta: peerMeta,
                approveCompletion: { controller, approved in
                    controller.dismissAnimated()
                    let ethereum = Ethereum.shared
                    if approved {
                        if let transactionHash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) {
                            let response = ResponseToExtension(id: request.id, name: request.name, result: transactionHash)
                            self.respondTo(request: request, response: response, on: controller)
                        } else {
                            self.showErrorAlert()
                        }
                    } else {
                        controller.dismissAnimated()
                    }
                }, on: self)
        case .signMessage:
            guard let data = request.message, let wallet = WalletsManager.shared.getWallet(address: request.address), let address = wallet.ethereumAddress else {
                self.showErrorAlert()
                return
            }
            Presenter.Crypto.Extension.showApproveOperation(subject: .signMessage, address: address, meta: data.hexString, peerMeta: peerMeta, approveCompletion: { controller, approved in
                if approved {
                    let ethereum = Ethereum.shared
                    if let signed = try? ethereum.sign(data: data, wallet: wallet) {
                        let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
                        self.respondTo(request: request, response: response, on: self)
                    } else {
                        self.showErrorAlert()
                    }
                } else {
                    controller.dismissAnimated()
                }
            }, on: self)
        case .signTypedMessage:
            print("signTypedMessage operation will support later")
            SPAlert.present(message: "signTypedMessage operation will support later", haptic: .warning, completion: nil)
        case .signPersonalMessage:
            print("signPersonalMessage operation will support later")
            SPAlert.present(message: "signPersonalMessage operation will support later", haptic: .warning, completion: nil)
        case .ecRecover:
            print("ecRecover operation will support later")
            SPAlert.present(message: "ecRecover operation will support later", haptic: .warning, completion: nil)
        case .addEthereumChain, .switchEthereumChain, .watchAsset:
            print("addEthereumChain / switchEthereumChain / watchAsset operation will support later")
            SPAlert.present(message: "addEthereumChain / switchEthereumChain / watchAsset operation will support later", haptic: .warning, completion: nil)
        }
    }
    
    private func respondTo(request: SafariRequest, response: ResponseToExtension, on controller: UIViewController) {
        ExtensionBridge.respond(id: request.id, response: response)
        UIApplication.shared.open(URL.blankRedirect(id: request.id)) { _ in
            controller.dismissAnimated()
        }
    }
    
    private func showErrorAlert() {
        SPAlert.present(message: "Something went wrong", haptic: .error, completion: nil)
    }
    /*
     private func presentForSafariRequest(_ viewController: UIViewController, id: Int) {
     var presentFrom: UIViewController = self
     while let presented = presentFrom.presentedViewController, !(presented is UIAlertController) {
     presentFrom = presented
     }
     if let alert = presentFrom.presentedViewController as? UIAlertController {
     alert.dismiss(animated: false)
     }
     presentFrom.present(viewController, animated: true)
     toDismissAfterResponse[id] = viewController
     }*/
}
