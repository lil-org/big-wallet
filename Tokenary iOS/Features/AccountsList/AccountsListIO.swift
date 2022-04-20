// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit

protocol AccountsListInput: LifecycleObserver, UITableViewDelegate, UITableViewDataSource {
    var mode: AccountsListMode { get }
    
    func createNewAccountAndShowSecretWordsFor(chains: [ChainType])
    func cancelButtonWasTapped()
    func didSelect(chain: EthereumChain)
    func didSelect(wallet: TokenaryWallet)
}

protocol AccountsListOutput: DataStateContainer {
    var tableView: UITableView { get }
    
    func showKey(wallet: TokenaryWallet, mnemonic: Bool)
    func didTapRemove(wallet: TokenaryWallet)
    func didTapExport(wallet: TokenaryWallet)
    func openSafari(requestId: Int)
    func presentForSafariRequest(_ viewController: UIViewController, id: Int)
    func scrollToTopNow()
}
