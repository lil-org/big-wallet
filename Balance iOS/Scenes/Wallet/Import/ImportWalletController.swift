import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SPAlert

class ImportWalletController: NativeOnboardingActionsController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    // MARK: - Init
    
    init() {
        super.init(
            iconImage: .init(SFSymbol.wallet.passFill),
            title: "Add or Import Wallet",
            subtitle: "You can choose import or create new wallet. Will add it to keychain."
        )
        setActions([
            .init(
                iconImage: .init(.doc.fillBadgePlus).withTintColor(.systemColorfulColors.randomElement()!, renderingMode: .alwaysTemplate),
                title: "Create New",
                description: "We will show you special words after create new wallet.",
                action: {
                    guard let parent = self.presentingViewController else { return}
                    let walletsManager = WalletsManager.shared
                    guard let wallet = try? walletsManager.createWallet() else { return }
                    NotificationCenter.default.post(name: .walletsUpdated, object: nil)
                    self.dismiss(animated: true, completion: {
                        Presenter.Crypto.showPhracesOnboarding(for: wallet, on: parent)
                    })
                }
            ),
            .init(
                iconImage: .init(.arrow.downDocFill),
                title: "Add Existing",
                description: "You can import by anyway like passphrase, private key or files.",
                action: {
                    guard let parent = self.presentingViewController else { return }
                    self.dismiss(animated: true) {
                        let importAccountViewController = instantiate(ImportViewController.self, from: .main)
                        parent.present(importAccountViewController.wrapToNavigationController(prefersLargeTitles: true), animated: true)
                    }
                }
            )
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = closeBarButtonItem
        scrollView.showsVerticalScrollIndicator = false
    }
}
