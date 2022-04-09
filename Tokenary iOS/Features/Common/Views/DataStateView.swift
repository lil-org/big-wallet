// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
import BlockiesSwift

enum DataState: CaseIterable {
    case hasData, loading, failedToLoad, noData, unknown
}

protocol DataStateContainer: AnyObject {
    
    var dataState: DataState { get set }
    func configureDataState(_ dataState: DataState, description: String?, image: UIImage?, buttonTitle: String?, actionHandler: ((CGRect) -> Void)?)
    func updateDataState(menu: UIMenu)
    func updateDataState(actionHandler: @escaping UIActionHandler)
}

class DataStateView: UIView {
    
    private class Configuration {
        
        let description: String?
        let image: UIImage?
        let buttonTitle: String?
        let actionHandler: ((CGRect) -> Void)?
        
        init(description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: ((CGRect) -> Void)? = nil) {
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
        let view = DataStateView.fromNib
        view.tag = tag
        view.isHidden = true
        return view
    }
    
    fileprivate var currentState = DataState.unknown {
        didSet { updateForCurrentState() }
    }
    
    private var configurations = [DataState: Configuration]()
    
    @IBOutlet private weak var centerYConstraint: NSLayoutConstraint!
    @IBOutlet private weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet private weak var imageView: UIImageView!
    @IBOutlet private weak var descriptionLabel: UILabel!
    @IBOutlet fileprivate weak var button: UIButton!
    @IBOutlet private weak var activityIndicatorDescriptionLabel: UILabel! {
        didSet {
            activityIndicatorDescriptionLabel.text = Strings.loading.uppercased()
        }
    }
    
    @IBAction private func didTapButton(_ sender: Any) {
        configurations[currentState]?.actionHandler?(button.frame)
    }
    
    fileprivate func configureDataState(_ dataState: DataState, description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: ((CGRect) -> Void)? = nil) {
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
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {

       let hitView = super.hitTest(point, with: event)

       return hitView
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
    
    func setDataStateViewTransparent(_ isTransparent: Bool) {
        dataStateView.backgroundColor = isTransparent ? .clear : .systemGroupedBackground
    }
    
    func configureDataState(_ dataState: DataState, description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: ((CGRect) -> Void)? = nil) {
        dataStateView.configureDataState(dataState, description: description, image: image, buttonTitle: buttonTitle, actionHandler: actionHandler)
    }
    
    func updateDataState(menu: UIMenu) {
        dataStateView.button.menu = menu
        dataStateView.button.showsMenuAsPrimaryAction = true
    }
    
    func updateDataState(actionHandler: @escaping UIActionHandler) {
        dataStateView.button.addAction(for: .touchUpInside, handler: actionHandler)
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
