// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

enum AccountsListMode: Equatable {
    case choseAccount(forChain: ChainType?)
    case mainScreen
    
    var isFilteringAccounts: Bool {
        if
            case let .choseAccount(forChain: chainType) = self, chainType == nil || self == .mainScreen
        {
            return true
        } else {
            return false
        }
    }
}

final class AccountsListAssembly {
#if canImport(UIKit)
    static func build(
        for mode: AccountsListMode,
        onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)? = nil
    ) -> UIViewController {
        let presenter = AccountsListPresenter(
            walletsManager: WalletsManager.shared,
            onSelectedWallet: onSelectedWallet,
            mode: mode
        )
        let viewController = AccountsListViewController(
            walletsManager: WalletsManager.shared,
            presenter: presenter
        )
        
        presenter.view = viewController
        
        return viewController.inNavigationController
    }
    
#elseif canImport(AppKit)
    
    static func build(
        for mode: AccountsListMode,
        newWalletId: String? = nil,
        onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)? = nil
    ) -> NSViewController {
        let stateProvider = AccountsListStateProvider(
            mode: mode
        )
        let contentView = AccountsListContentHolderView()
            .environmentObject(stateProvider)
        
        let wrappingVC = WrappingViewController(rootView: contentView)
        
        let hostingVC = NSStoryboard.main.instantiateController(
            identifier: String(describing: AccountsListViewController.self)
        ) { coder in
            AccountsListViewController(
                coder: coder, walletsManager: WalletsManager.shared, agent: Agent.shared, wrappingVC: wrappingVC
            )
        }.then {
            $0.onSelectedWallet = onSelectedWallet
            $0.newWalletId = newWalletId
        }
        
        stateProvider.output = hostingVC
        hostingVC.stateProviderInput = stateProvider
        
        return hostingVC
    }
#endif
}
