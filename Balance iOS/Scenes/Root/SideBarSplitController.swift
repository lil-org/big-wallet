import UIKit
import SparrowKit
import SPDiffable
import Constants

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
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !Flags.seen_tutorial {
            Presenter.App.showOnboarding(on: self, afterAction: {
                Presenter.Crypto.showWalletOnboarding(on: self)
            })
        }
    }
}
