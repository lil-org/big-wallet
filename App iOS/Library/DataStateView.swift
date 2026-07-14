// ∅ 2026 lil org

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
        let view = DataStateView(frame: .zero)
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
    
    private var centerYConstraint: NSLayoutConstraint!
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let imageView = UIImageView()
    private let descriptionLabel = UILabel()
    private let button = UIButton(type: .system)
    private let activityIndicatorDescriptionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .systemGroupedBackground

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.isOpaque = false
        activityIndicator.startAnimating()
        activityIndicator.isHidden = true
        addSubview(activityIndicator)

        activityIndicatorDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        activityIndicatorDescriptionLabel.isOpaque = false
        activityIndicatorDescriptionLabel.isHidden = true
        activityIndicatorDescriptionLabel.font = .systemFont(ofSize: 12)
        activityIndicatorDescriptionLabel.textColor = .secondaryLabel
        activityIndicatorDescriptionLabel.text = Strings.loading
        activityIndicatorDescriptionLabel.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        activityIndicatorDescriptionLabel.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        addSubview(activityIndicatorDescriptionLabel)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(systemName: "wind")
        imageView.tintColor = .tertiaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(scale: .default)
            .applying(UIImage.SymbolConfiguration(weight: .thin))
        imageView.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        imageView.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        addSubview(imageView)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.isOpaque = false
        descriptionLabel.font = .systemFont(ofSize: 17)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.text = "failed to load"
        descriptionLabel.textAlignment = .center
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.numberOfLines = 2
        descriptionLabel.setContentHuggingPriority(UILayoutPriority(251), for: .horizontal)
        descriptionLabel.setContentHuggingPriority(UILayoutPriority(251), for: .vertical)
        addSubview(descriptionLabel)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.titleLabel?.lineBreakMode = .byTruncatingMiddle
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "retry"
        var attributedButtonTitle = AttributedString("retry")
        attributedButtonTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        buttonConfiguration.attributedTitle = attributedButtonTitle
        button.configuration = buttonConfiguration
        button.addTarget(self, action: #selector(didTapButton(_:)), for: .touchUpInside)
        addSubview(button)

        centerYConstraint = activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -50)
        let proportionalImageWidthConstraint = imageView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 3 / 7)
        proportionalImageWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 150),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            proportionalImageWidthConstraint,

            descriptionLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            descriptionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            descriptionLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -40),

            button.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 52),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.heightAnchor.constraint(equalToConstant: 52),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -58.5),
            centerYConstraint,

            activityIndicatorDescriptionLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 8),
            activityIndicatorDescriptionLabel.centerXAnchor.constraint(equalTo: activityIndicator.centerXAnchor)
        ])
    }
    
    @objc private func didTapButton(_ sender: Any) {
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
    
    func configureDataState(_ dataState: DataState, description: String? = nil, image: UIImage? = nil, buttonTitle: String? = nil, actionHandler: (() -> Void)? = nil) {
        dataStateView.configureDataState(dataState, description: description, image: image, buttonTitle: buttonTitle, actionHandler: actionHandler)
    }
    
    private var dataStateView: DataStateView {
        if let subview = view.viewWithTag(DataStateView.tag) as? DataStateView { return subview }
        
        let dataStateView = DataStateView.new
        view.addSubview(dataStateView)
        dataStateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dataStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dataStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dataStateView.topAnchor.constraint(equalTo: view.topAnchor),
            dataStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.bringSubviewToFront(dataStateView)
        return dataStateView
    }
}
