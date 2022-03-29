// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

public enum AccountsListMode: Equatable {
    case choseAccount(forChain: ChainType?)
    case mainScreen
}

public final class AccountsListAssembly {
#if canImport(UIKit)
    public static func build(
        for mode: AccountsListMode,
        onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)? = nil
    ) -> UIViewController {
        UITableView.appearance().tableHeaderView = UIView(
            frame: CGRect(x: .zero, y: .zero, width: .zero, height: CGFloat.leastNormalMagnitude)
        )
        UINavigationBar.appearance().isHidden = true
        let stateProvider = AccountsListStateProvider(
            mode: mode
        )
        let contentView = AccountsListView()
            .environmentObject(stateProvider)
        
        let hostingVC = AccountsListViewController(
            walletsManager: WalletsManager.shared,
            rootView: contentView
        ).then {
            // This is done, so the empty DataState viewer appears
            //  to be presented beneath SwiftUI navigation thingy
            $0.swiftUIHostingController.view.backgroundColor = .clear
            $0.view.backgroundColor = .clear
            
            $0.onSelectedWallet = onSelectedWallet
        }
        
        stateProvider.output = hostingVC
        hostingVC.stateProviderInput = stateProvider
        
        return hostingVC
    }
    
#elseif canImport(AppKit)
    
    public static func build(
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
