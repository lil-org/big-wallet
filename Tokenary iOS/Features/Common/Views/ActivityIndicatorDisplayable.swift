// Copyright © 2022 Tokenary. All rights reserved.
// Present and hide activity indicator on any controller

import Foundation
import UIKit

protocol ActivityIndicatorDisplayable {
    func showActivityIndicator(on controller: UIViewController?)
    func hideActivityIndicator()
}

extension ActivityIndicatorDisplayable where Self: UIViewController {
    func showActivityIndicator(on controller: UIViewController? = nil) {
        let presentingVC = controller ?? tabBarController ?? navigationController ?? self
        let superView = presentingVC.view!
        let activityIndicatorView = UIActivityIndicatorView(style: .medium).then {
            $0.transform = CGAffineTransform(scaleX: .zero, y: .zero)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let activityIndicatorHolderView = ViewContainer(
            wrappedView: activityIndicatorView, viewController: presentingVC
        ).then {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        
        if let navigationVC = presentingVC as? UINavigationController {
            navigationVC.interactivePopGestureRecognizer?.isEnabled = false
        } else {
            presentingVC.navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }
        
        superView.add { activityIndicatorHolderView }
        NSLayoutConstraint.activate {
            activityIndicatorHolderView.topAnchor.constraint(equalTo: superView.topAnchor)
            activityIndicatorHolderView.bottomAnchor.constraint(equalTo: superView.bottomAnchor)
            activityIndicatorHolderView.leadingAnchor.constraint(equalTo: superView.leadingAnchor)
            activityIndicatorHolderView.trailingAnchor.constraint(equalTo: superView.trailingAnchor)
        }

        self.activityIndicatorHolderView = activityIndicatorHolderView
        
        UIView.animate(withDuration: 0.15) {
            activityIndicatorView.transform = .identity
        }

        view.endEditing(true)
        superView.endEditing(true)
        
        activityIndicatorView.startAnimating()
    }
    
    func hideActivityIndicator() {
        guard let activityIndicatorHolderView = self.activityIndicatorHolderView else { return }
        
        let presentingVC = activityIndicatorHolderView.viewController
        
        if let navigationVC = presentingVC as? UINavigationController {
            navigationVC.interactivePopGestureRecognizer?.isEnabled = true
        } else {
            presentingVC?.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
        UIView.animate(
            withDuration: 0.15,
            animations: {
                activityIndicatorHolderView.wrappedView.alpha = .zero
                activityIndicatorHolderView.wrappedView.transform = CGAffineTransform(scaleX: .zero, y: .zero)
            },
            completion: { _ in
                activityIndicatorHolderView.removeFromSuperview()
                activityIndicatorHolderView.wrappedView.removeFromSuperview()
                self.activityIndicatorHolderView = nil
            }
        )
    }
    
    private var activityIndicatorHolderView: ViewContainer<UIActivityIndicatorView>? {
        get {
            objc_getAssociatedObject(
                self, &AssociatedKeys.activityIndicatorView
            ) as? ViewContainer<UIActivityIndicatorView>
        }
        set {
            objc_setAssociatedObject(
                self, &AssociatedKeys.activityIndicatorView, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

private struct AssociatedKeys {
    static var activityIndicatorView = "ActivityIndicatorView"
}

private final class ViewContainer<T: UIView>: UIView {
    weak var viewController: UIViewController?
    var wrappedView: T

    init(wrappedView: T, viewController: UIViewController?) {
        self.wrappedView = wrappedView
        self.viewController = viewController
        super.init(frame: .zero)
        
        commonInit()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func commonInit() {
        setupStyle()
        addSubviews()
        makeConstraints()
    }
    
    private func setupStyle() { backgroundColor = .clear }
    
    private func addSubviews() { add { wrappedView } }
    
    private func makeConstraints() {
        NSLayoutConstraint.activate {
            wrappedView.centerYAnchor.constraint(equalTo: centerYAnchor)
            wrappedView.centerXAnchor.constraint(equalTo: centerXAnchor)
        }
    }
}
