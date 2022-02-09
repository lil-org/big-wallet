import UIKit
import SparrowKit
import NativeUIKit
import SPSafeSymbols
import SPAlert

class ImportWalletController: NativeOnboardingActionsController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    // MARK: - Init
    
    init() {
        super.init(
            iconImage: .init(SPSafeSymbol.wallet.passFill),
            title: Texts.Wallet.Import.title,
            subtitle: Texts.Wallet.Import.description
        )
        setActions([
            .init(
                iconImage: .init(.doc.fillBadgePlus).withTintColor(.systemColorfulColors.randomElement()!, renderingMode: .alwaysTemplate),
                title: Texts.Wallet.Import.action_new_title,
                description: Texts.Wallet.Import.action_new_description,
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
                title: Texts.Wallet.Import.action_add_exising_title,
                description: Texts.Wallet.Import.action_add_exising_description,
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
