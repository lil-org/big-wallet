// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

// Pack 1
// - Touch actions:
//  - Empty space:
//      - change color, show wallet actions
//  - Account(on general screen) - show account actions
//  - Account(on select) - select
// - Add account filtering
// Pack 2
// - Fix account derivation time:
//  - move to background
//  - async wrapper, produce one by one?
//  - stop deriving addresses per request(cache them)
// - Fix name redraw lag(remove save?)
// Pack 3
// - Add iPad support
//  - Check drop-down views
//  - overal-design
// - Add normal pagination to ExpandableGrid
// - Top navigation padding
//  - Try UINavigationBar
//  - Drop SwiftUI NavigationView, by custom redraw
// Pack 4
// - Prepare MR as per ivans' suggestion
// - Drop MacOS integraion
// check everything final, make mr


// везде показывать одинкаовый аддрес
// для эфира показывать картику
// для мнепоинмков показываем всегда эфир
// уменьшить картнку, увеличить заголовок - убрать надпись multi-coin wallet
// взять фотки у траста
// откатить дефолтное название для кошелька
// один эмотикон
//

// https://github.com/trustwallet/assets

public enum AccountsListMode: Equatable {
    case choseAccount(forChain: SupportedChainType?)
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
        
        let hostingVC = ALViewController(
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
        let contentView = AccountsListView()
            .environmentObject(stateProvider)
        
        let wrappingVC = WrappingViewController(rootView: contentView)
        
        let hostingVC = NSStoryboard.main.instantiateController(
            identifier: String(describing: ALViewController.self)
        ) { coder in
            ALViewController(
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
