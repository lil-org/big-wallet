import UIKit
import SparrowKit
import NativeUIKit
import SPSafeSymbols

class OnboardingBenefitsController: NativeOnboardingFeaturesController, OnboardingChildInterface {
    
    weak var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    let actionToolbarView = NativeLargeActionToolBarView().do {
        $0.actionButton.set(
            title: Texts.App.Onboarding.features_title,
            icon: .init(.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
    }
    
    // MARK: - Init
    
    init() {
        super.init(
            iconImage: .init(SPSafeSymbol.wallet.passFill),
            title: Texts.App.Onboarding.features_title,
            subtitle: Texts.App.Onboarding.features_description
        )
        setFeatures([
            .init(
                iconImage: .init(SPSafeSymbol.safari).withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
                title: Texts.App.Onboarding.features_1_title,
                description: Texts.App.Onboarding.features_1_description
            ),
            .init(
                iconImage: .init(SPSafeSymbol.key.fill).withTintColor(.systemGreen, renderingMode: .alwaysOriginal),
                title: Texts.App.Onboarding.features_2_title,
                description: Texts.App.Onboarding.features_2_description
            ),
            .init(
                iconImage: .init(SPSafeSymbol.envelope.fill).withTintColor(.systemIndigo, renderingMode: .alwaysOriginal),
                title: Texts.App.Onboarding.features_3_title,
                description: Texts.App.Onboarding.features_3_description
            ),
            .init(
                iconImage: .init(SPSafeSymbol.person._3Fill).withTintColor(.systemOrange, renderingMode: .alwaysOriginal),
                title: Texts.App.Onboarding.features_4_title,
                description: Texts.App.Onboarding.features_4_description
            )
        ])
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
