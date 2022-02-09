import UIKit
import SparrowKit
import NativeUIKit
import SPSafeSymbols
import SPAlert

class ArchivedImportWalletController: NativeHeaderController, OnboardingChildInterface {
    
    var onboardingManagerDelegate: OnboardingManagerDelegate?
    
    var segmentButtons: [ImportWalletSegmentButton] = []
    
    let actionToolbarView = NativeLargeSmallActionToolBarView().do {
        $0.actionButton.set(
            title: "Choose",
            icon: UIImage(SPSafeSymbol.checkmark.circleFill),
            colorise: .init(content: .custom(.white), background: .tint)
        )
        $0.secondActionButton.setTitle("Cancel")
    }
    
    // MARK: - Init
    
    init() {
        super.init(image: nil, title: "Add or Import Wallet", subtitle: "You can choose import or create new wallet. Will add it to keychain.")
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
        
        let newSegmentButton = ImportWalletSegmentButton()
        newSegmentButton.headerLabel.text = "Create New"
        newSegmentButton.iconImageView.image = .init(.doc.fillBadgePlus)
        newSegmentButton.descriptionLabel.text = "We will show you special words after create new wallet."
        segmentButtons.append(newSegmentButton)
        
        let addSegmentButton = ImportWalletSegmentButton()
        addSegmentButton.headerLabel.text = "Add Existing"
        addSegmentButton.iconImageView.image = .init(.arrow.downDocFill)
        addSegmentButton.descriptionLabel.text = "You can import by anyway like passphrase, private key or files."
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
        guard let parent = self.presentingViewController else { return}
        if segmentButtons.first?.appearance == .selected {
            let walletsManager = WalletsManager.shared
            guard let wallet = try? walletsManager.createWallet() else { return }
            NotificationCenter.default.post(name: .walletsUpdated, object: nil)
            self.dismiss(animated: true, completion: {
                Presenter.Crypto.showPhracesOnboarding(for: wallet, on: parent)
            })
        } else {
            self.dismiss(animated: true) {
                let importAccountViewController = instantiate(ImportViewController.self, from: .main)
                parent.present(importAccountViewController.wrapToNavigationController(prefersLargeTitles: true), animated: true)
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
