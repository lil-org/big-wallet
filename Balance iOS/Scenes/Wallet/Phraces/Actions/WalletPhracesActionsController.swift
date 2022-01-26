import UIKit
import SparrowKit
import NativeUIKit
import SFSymbols
import SPAlert

class WalletPhracesActionsController: NativeHeaderController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    internal var segmentButtons: [WalletPhracesActionSegmentButton] = []
    
    internal let actionToolbarView = NativeLargeSmallActionToolBarView().do {
        $0.actionButton.set(
            title: "Choose",
            icon: UIImage(SFSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.secondActionButton.setTitle("Cancel")
    }
    
    internal var phraces: [String] = []
    
    // MARK: - Init
    
    init(phraces: [String]) {
        super.init(image: nil, title: "Save Wallet Phraces", subtitle: "Keep it private becouse it access to your wallet.")
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
        newSegmentButton.headerLabel.text = "Copy to Clipboard"
        newSegmentButton.iconImageView.image = .init(.doc.onDocFill)
        newSegmentButton.descriptionLabel.text = "We paste all words to clipboard. You can paste it anywhere."
        segmentButtons.append(newSegmentButton)
        
        let addSegmentButton = WalletPhracesActionSegmentButton()
        addSegmentButton.headerLabel.text = "Share"
        addSegmentButton.iconImageView.image = .init(.square.andArrowUpCircleFill)
        addSegmentButton.descriptionLabel.text = "You can share text to any app, notes for example."
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
        var phraces = ""
        for phrace in phraces {
            phraces = phraces + (String(phrace) + " ")
        }
        if segmentButtons.first?.appearance == .selected {
            self.dismiss(animated: true, completion: {
                SPAlert.present(title: "Copied to Clipboard", message: nil, preset: .done, completion: nil)
            })
        } else {
            self.dismiss(animated: true) {
                let textToShare = [phraces]
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
