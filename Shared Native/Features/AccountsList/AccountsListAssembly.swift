// Copyright © 2022 Tokenary. All rights reserved.
// Assmebly

import Foundation
import UIKit
import SwiftUI

public enum AccountsListMode: Equatable {
    case choseAccount(forChain: SupportedChainType?)
    case mainScreen
}

public final class AccountsListAssembly {
    public static func build(
        for mode: AccountsListMode,
        onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)? = nil
    ) -> UIViewController {
        UINavigationBar.appearance().setBackgroundImage(UIImage(), for: .default)
           UINavigationBar.appearance().shadowImage = UIImage()
        UITableView.appearance().tableHeaderView = UIView(frame: CGRect(x: .zero, y: .zero, width: .zero, height: CGFloat.leastNormalMagnitude))
        let stateProvider = AccountsListStateProvider(
            mode: mode
        )
        let contentView = AccountsListView()
            .environmentObject(stateProvider)
        
        let hostingVC = ALViewController(
            walletsManager: WalletsManager.shared,
            rootView: contentView
        ).then {
            // This is done, so the empty DataState viewer appear to be presented beneath SwiftUI navigation thingy
            $0.swiftUIHostingController.view.backgroundColor = .clear
            $0.view.backgroundColor = .clear
            
            $0.onSelectedWallet = onSelectedWallet
        }
        
        stateProvider.output = hostingVC
        hostingVC.stateProviderInput = stateProvider
        
        return hostingVC
    }
}
