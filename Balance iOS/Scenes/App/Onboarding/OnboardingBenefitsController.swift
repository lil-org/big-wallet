import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols

class OnboardingBenefitsController: NativeOnboardingController, OnboardingChildInterface {
     
    weak var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: "Start Using",
            icon: .init(.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
    }
    
    // MARK: - Init
    
    init() {
        super.init(
            iconImage: .init(SFSymbol.wallet.passFill),
            title: "Features",
            subtitle: "Check list our features, we will add more.",
            items: [
                .init(
                    iconImage: .init(SFSymbol.safari).withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                    title: "Safari Extension",
                    description: "You can use ETH without opening main app at all. We will show you how integrate it and how use it next."
                ),
                .init(
                    iconImage: .init(SFSymbol.key.fill).withTintColor(.systemGreen, renderingMode: .alwaysOriginal),
                    title: "Safety",
                    description: "We don't transfer passwords or any keys. Its stored only at your device and don't worry about safety."
                ),
                .init(
                    iconImage: .init(SFSymbol.envelope.fill).withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                    title: "Open Source",
                    description: "All app published like open source, so you can check code and even do great changes. We do it for comunity and happy to have progress in it."
                ),
                .init(
                    iconImage: .init(SFSymbol.person._3Fill).withTintColor(.systemOrange, renderingMode: .alwaysOriginal),
                    title: "Internation Team",
                    description: "So many designers and engineers make this app. You can be sure that they are high-level specialists."
                )
            ]
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.showsVerticalScrollIndicator = false
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        actionToolbarView.actionButton.addAction(.init(handler: { _ in
            self.onboardingManagerDelegate?.onboardingActionComplete(for: self)
        }), for: .touchUpInside)
    }
    
    #warning("temp")
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        delay(0.1, closure: {
            self.scrollViewDidScroll(self.scrollView)
        })
    }
}
