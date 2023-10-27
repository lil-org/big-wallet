// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

enum DataState: CaseIterable {
    case hasData, loading, failedToLoad, noData, unknown
}

protocol DataStateContainer: AnyObject {
    
    var dataState: DataState { get set }
    func configureDataState(_ dataState: DataState, description: String?, image: UIImage?, buttonTitle: String?, actionHandler: (() -> Void)?)
}

class DataStateView: UIView {
    
    private class Configuration {
        
        let description: String?
        let image: UIImage?
        let buttonTitle: String?
        let actionHandler: (() -> Void)?
        
        init(description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: (() -> Void)? = nil) {
            self.description = description
            self.image = image
            self.buttonTitle = buttonTitle
            self.actionHandler = actionHandler
        }
        
        static func defaultForDataState(_ dataState: DataState) -> Configuration {
            let configuration: Configuration
            switch dataState {
            case .hasData, .loading, .unknown:
                configuration = Configuration()
            case .failedToLoad:
                configuration = Configuration(description: Strings.failedToLoad, image: Images.failedToLoad, buttonTitle: Strings.tryAgain)
            case .noData:
                configuration = Configuration(description: Strings.noData, image: Images.noData, buttonTitle: Strings.refresh)
            }
            return configuration
        }
    }
    
    fileprivate static let tag = Int.max
    fileprivate static var new: DataStateView {
        let view = loadNib(DataStateView.self)
        view.tag = tag
        view.isHidden = true
        view.observeKeyboard()
        return view
    }
    
    fileprivate var shouldMoveWithKeyboard = true
    fileprivate var currentState = DataState.unknown {
        didSet { updateForCurrentState() }
    }
    
    private var configurations = [DataState: Configuration]()
    
    @IBOutlet private weak var centerYConstraint: NSLayoutConstraint!
    @IBOutlet private weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet private weak var imageView: UIImageView!
    @IBOutlet private weak var descriptionLabel: UILabel!
    @IBOutlet private weak var button: UIButton!
    @IBOutlet private weak var activityIndicatorDescriptionLabel: UILabel! {
        didSet {
            activityIndicatorDescriptionLabel.text = Strings.loading.uppercased()
        }
    }
    
    @IBAction private func didTapButton(_ sender: Any) {
        configurations[currentState]?.actionHandler?()
    }
    
    fileprivate func configureDataState(_ dataState: DataState, description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: (() -> Void)? = nil) {
        let newConfiguration = Configuration(description: description, image: image, buttonTitle: buttonTitle, actionHandler: actionHandler)
        configurations[dataState] = newConfiguration
    }
    
    private func updateForCurrentState() {
        isHidden = currentState == .unknown || currentState == .hasData
        
        let configuration = configurations[currentState]
        let defaultConfiguration = Configuration.defaultForDataState(currentState)
        
        imageView.image = configuration?.image ?? defaultConfiguration.image
        descriptionLabel.text = configuration?.description ?? defaultConfiguration.description
        button.setTitle(configuration?.buttonTitle ?? defaultConfiguration.buttonTitle, for: .normal)
        
        let isLoading = currentState == .loading
        
        activityIndicator.isHidden = !isLoading
        activityIndicatorDescriptionLabel.isHidden = !isLoading
        imageView.isHidden = isLoading
        descriptionLabel.isHidden = isLoading
        button.isHidden = isLoading || configuration?.actionHandler == nil
        
        if isLoading {
            activityIndicator.startAnimating()
        } else if activityIndicator.isAnimating {
            activityIndicator.stopAnimating()
        }
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return button.frame.insetBy(dx: -30, dy: -30).contains(point)
    }
    
}

extension DataStateView: KeyboardObserver {
    
    func keyboardWill(show: Bool, height: CGFloat, animtaionOptions: UIView.AnimationOptions, duration: Double) {
        guard shouldMoveWithKeyboard else { return }
        let centerOffset: CGFloat = show ? -105 : -50

        UIView.animate(withDuration: duration,
            delay: 0,
            options: animtaionOptions,
            animations: { [weak self] in
                self?.centerYConstraint.constant = centerOffset
                self?.layoutIfNeeded()
            },
            completion: nil
        )
    }
    
}

extension DataStateContainer where Self: UIViewController {
    
    var dataState: DataState {
        get {
            return dataStateView.currentState
        }
        set {
            dataStateView.currentState = newValue
        }
    }
    
    func dataStateShouldMoveWithKeyboard(_ shouldMove: Bool) {
        dataStateView.shouldMoveWithKeyboard = shouldMove
    }
    
    func setDataStateViewTransparent(_ isTransparent: Bool) {
        dataStateView.backgroundColor = isTransparent ? .clear : .systemGroupedBackground
    }
    
    func configureDataState(_ dataState: DataState, description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: (() -> Void)? = nil) {
        dataStateView.configureDataState(dataState, description: description, image: image, buttonTitle: buttonTitle, actionHandler: actionHandler)
    }
    
    private var dataStateView: DataStateView {
        if let subview = view.viewWithTag(DataStateView.tag) as? DataStateView { return subview }
        
        let dataStateView = DataStateView.new
        view.addSubview(dataStateView)
        dataStateView.translatesAutoresizingMaskIntoConstraints = false
        let firstConstraint = NSLayoutConstraint.constraints(withVisualFormat: "H:|-0-[subview]-0-|", options: .directionLeadingToTrailing, metrics: nil, views: ["subview": dataStateView])
        let secondConstraint = NSLayoutConstraint.constraints(withVisualFormat: "V:|-0-[subview]-0-|", options: .directionLeadingToTrailing, metrics: nil, views: ["subview": dataStateView])
        view.addConstraints(firstConstraint + secondConstraint)
        view.bringSubviewToFront(dataStateView)
        return dataStateView
    }
}
