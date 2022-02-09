import UIKit
import SparrowKit
import NativeUIKit
import SPSafeSymbols
import SPAlert

class WalletPhracesActionsController: NativeHeaderController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    internal var segmentButtons: [WalletPhracesActionSegmentButton] = []
    
    internal let actionToolbarView = NativeLargeSmallActionToolBarView().do {
        $0.actionButton.set(
            title: Texts.Wallet.Phrase.Actions.choose,
            icon: UIImage(SPSafeSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.secondActionButton.setTitle(Texts.Wallet.Phrase.Actions.cancel)
    }
    
    internal var phraces: [String]
    
    // MARK: - Init
    
    init(phraces: [String]) {
        self.phraces = phraces
        super.init(image: nil, title: Texts.Wallet.Phrase.Actions.title, subtitle: Texts.Wallet.Phrase.Actions.description)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        navigationItem.rightBarButtonItem = closeBarButtonItem
        scrollView.showsVerticalScrollIndicator = false
        
        let newSegmentButton = WalletPhracesActionSegmentButton()
        newSegmentButton.headerLabel.text = Texts.Wallet.Phrase.Actions.action_copy_title
        newSegmentButton.iconImageView.image = .init(.doc.onDocFill)
        newSegmentButton.descriptionLabel.text = Texts.Wallet.Phrase.Actions.action_copy_description
        segmentButtons.append(newSegmentButton)
        
        let addSegmentButton = WalletPhracesActionSegmentButton()
        addSegmentButton.headerLabel.text = Texts.Wallet.Phrase.Actions.action_share_title
        addSegmentButton.iconImageView.image = .init(.square.andArrowUpCircleFill)
        addSegmentButton.descriptionLabel.text = Texts.Wallet.Phrase.Actions.action_share_description
        segmentButtons.append(addSegmentButton)
        
        for (index, segmentButton) in segmentButtons.enumerated() {
            scrollView.addSubview(segmentButton)
            segmentButton.addTarget(self, action: #selector(didTapSegment(sender:)), for: .touchUpInside)
            segmentButton.appearance = index == .zero ? .selected : .default
        }
        
        if let navigationController = self.navigationController as? NativeNavigationController {
            navigationController.mimicrateToolBarView = actionToolbarView
        }
        
        actionToolbarView.actionButton.addTarget(self, action: #selector(self.didTapChoose), for: .touchUpInside)
        actionToolbarView.secondActionButton.addTarget(self, action: #selector(dismissAnimated), for: .touchUpInside)
    }
    
    // MARK: - Actions
    
    @objc func didTapSegment(sender: ImportWalletSegmentButton) {
        UIView.animate(withDuration: 0.08, delay: .zero, options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction], animations: {
            for segmentButton in self.segmentButtons {
                if segmentButton == sender {
                    segmentButton.appearance = .selected
                } else {
                    segmentButton.appearance = .default
                }
            }
            self.viewDidLayoutSubviews()
            
        }, completion: nil)
        UIFeedbackGenerator.impactOccurred(.light)
    }
    
    @objc func didTapChoose() {
        guard let parent = self.presentingViewController else { return }
        var phracesFormtatted = ""
        for phrace in phraces {
            phracesFormtatted = phracesFormtatted + (String(phrace) + " ")
        }
        print("ph \(phracesFormtatted), \(phraces)")
        if segmentButtons.first?.appearance == .selected {
            UIPasteboard.general.string = phracesFormtatted
            SPAlert.present(title: Texts.Wallet.Phrase.Actions.action_copy_completed, message: nil, preset: .done, completion: nil)
            self.dismissAnimated()
        } else {
            self.dismiss(animated: true) {
                let textToShare = [phracesFormtatted]
                let activityViewController = UIActivityViewController(activityItems: textToShare, applicationActivities: nil)
                activityViewController.popoverPresentationController?.sourceView = self.segmentButtons[safe: 2]
                parent.present(activityViewController, animated: true, completion: nil)
            }
        }
    }
    
    // MARK: - Layout
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        let originX = scrollView.layoutMargins.left
        var currentOriginY: CGFloat = headerView.frame.maxY + NativeLayout.Spaces.default_double
        for view in segmentButtons {
            view.frame.setWidth(scrollView.layoutWidth)
            view.frame.origin = .init(x: originX, y: currentOriginY)
            view.sizeToFit()
            currentOriginY = view.frame.maxY + NativeLayout.Spaces.default_half
        }
        
        scrollView.contentSize = .init(
            width: view.frame.width,
            height: segmentButtons.last?.frame.maxY ?? 0
        )
    }
}
