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
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            ExtensionService.processInput(on: self)
        }
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
}
