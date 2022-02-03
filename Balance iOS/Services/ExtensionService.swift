import UIKit
import SPAlert

enum ExtensionService {
    
    static func processInput(on controller: UIViewController) {
        print("launchURL \(launchURL)")
        let prefix = "balance://"
        guard let url = launchURL?.absoluteString, url.hasPrefix(prefix),
              let request = SafariRequest(query: String(url.dropFirst(prefix.count))) else { return }
        launchURL = nil
        //print("req \(String(url.dropFirst(prefix.count)))")
        guard ExtensionBridge.hasRequest(id: request.id) else {
            SPAlert.present(message: "This operation will support later", haptic: .warning, completion: nil)
            return
        }
        
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.iconURLString)
        
        switch request.method {
        case .switchAccount, .requestAccounts:
            Presenter.Crypto.Extension.showLinkWallet(didSelectWallet: { wallet, chain, controller in
                guard let address = wallet.ethereumAddress else {
                    self.showErrorAlert("Can't get ETH Address")
                    return
                }
                let response = ResponseToExtension(id: request.id, name: request.name, results: [address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                self.respondTo(request: request, response: response, on: controller)
            }, on: controller)
        case .signTransaction:
            guard let transaction = request.transaction, let chain = request.chain, let wallet = WalletsManager.shared.getWallet(address: request.address), let address = wallet.ethereumAddress else {
                self.showErrorAlert("Missing some data in request (signTransaction)")
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
                        do {
                            let transactionHash = try ethereum.send(transaction: transaction, wallet: wallet, chain: chain)
                            let response = ResponseToExtension(id: request.id, name: request.name, result: transactionHash)
                            self.respondTo(request: request, response: response, on: controller)
                        } catch {
                            self.showErrorAlert(error.localizedDescription)
                            controller.dismissAnimated()
                            return
                        }
                    } else {
                        controller.dismissAnimated()
                    }
                }, on: controller)
        case .signMessage:
            guard let data = request.message, let wallet = WalletsManager.shared.getWallet(address: request.address), let address = wallet.ethereumAddress else {
                self.showErrorAlert("Missing some data in request (signMessage)")
                return
            }
            Presenter.Crypto.Extension.showApproveOperation(subject: .signMessage, address: address, meta: data.hexString, peerMeta: peerMeta, approveCompletion: { controller, approved in
                if approved {
                    do {
                        let ethereum = Ethereum.shared
                        let signed = try ethereum.sign(data: data, wallet: wallet)
                        let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
                        self.respondTo(request: request, response: response, on: controller)
                    } catch {
                        self.showErrorAlert(error.localizedDescription)
                    }
                } else {
                    controller.dismissAnimated()
                }
            }, on: controller)
        case .signPersonalMessage:
            guard let data = request.message, let wallet = WalletsManager.shared.getWallet(address: request.address), let address = wallet.ethereumAddress else {
                self.showErrorAlert("Missing some data in reques (signPersonalMessage)")
                return
            }
            let text = String(data: data, encoding: .utf8) ?? data.hexString
            Presenter.Crypto.Extension.showApproveOperation(subject: .signPersonalMessage, address: address, meta: text, peerMeta: peerMeta, approveCompletion: { controller, approved in
                if approved {
                    do {
                        let ethereum = Ethereum.shared
                        let signed = try ethereum.signPersonalMessage(data: data, wallet: wallet)
                        let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
                        self.respondTo(request: request, response: response, on: controller)
                    } catch {
                        self.showErrorAlert(error.localizedDescription)
                    }
                } else {
                    controller.dismissAnimated()
                }
            }, on: controller)
        case .signTypedMessage:
            guard let raw = request.raw, let wallet = WalletsManager.shared.getWallet(address: request.address), let address = wallet.ethereumAddress else {
                self.showErrorAlert("Missing some data in request (signTypedMessage)")
                return
            }
            Presenter.Crypto.Extension.showApproveOperation(subject: .signTypedData, address: address, meta: raw, peerMeta: peerMeta, approveCompletion: { controller, approved in
                if approved {
                    do {
                        let ethereum = Ethereum.shared
                        let signed = try ethereum.sign(typedData: raw, wallet: wallet)
                        let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
                        self.respondTo(request: request, response: response, on: controller)
                    } catch {
                        self.showErrorAlert(error.localizedDescription)
                    }
                } else {
                    controller.dismissAnimated()
                }
            }, on: controller)
        case .ecRecover:
            print("ecRecover operation will support later")
            SPAlert.present(message: "ecRecover operation will support later", haptic: .warning, completion: nil)
        case .addEthereumChain, .switchEthereumChain, .watchAsset:
            print("addEthereumChain / switchEthereumChain / watchAsset operation will support later")
            SPAlert.present(message: "addEthereumChain / switchEthereumChain / watchAsset operation will support later", haptic: .warning, completion: nil)
        }
    }
    
    static private func respondTo(request: SafariRequest, response: ResponseToExtension, on controller: UIViewController) {
        ExtensionBridge.respond(id: request.id, response: response)
        UIApplication.shared.open(URL.blankRedirect(id: request.id)) { _ in
            controller.dismissAnimated()
        }
    }
    
    static private func showErrorAlert(_ error: String? = nil) {
        SPAlert.present(message: error ?? "Something went wrong", haptic: .error, completion: nil)
    }
}
