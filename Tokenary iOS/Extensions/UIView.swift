// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

@resultBuilder
struct AddViewBuilder {
    static func buildBlock(_ views: UIView...) -> [UIView] { views }

    static func buildBlock(_ views: [UIView]) -> [UIView] { views }

    static func buildBlock(_ view: UIView?) -> [UIView] {
        guard let view = view else { return [] }
        return [view]
    }
}

extension UIView {
    static var fromNib: Self {
        Bundle.main.loadNibNamed(String(describing: Self.self), owner: nil, options: nil)![0] as! Self
    }
    
    func addSubviewConstrainedToFrame(_ subview: UIView) {
        addSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        let firstConstraints = NSLayoutConstraint.constraints(
            withVisualFormat: "H:|-0-[subview]-0-|",
            options: .directionLeadingToTrailing, metrics: nil,
            views: ["subview": subview]
        )
        let secondConstraints = NSLayoutConstraint.constraints(
            withVisualFormat: "V:|-0-[subview]-0-|",
            options: .directionLeadingToTrailing, metrics: nil,
            views: ["subview": subview]
        )
        addConstraints(firstConstraints + secondConstraints)
    }
    
    @discardableResult
    func add(@AddViewBuilder _ block: () -> ([UIView])) -> UIView {
        if let stackView = self as? UIStackView {
            block().forEach { stackView.addArrangedSubview($0) }
        } else {
            block().forEach { addSubview($0) }
        }
        return self
    }

    @discardableResult
    func add(_ views: [UIView]) -> UIView {
        if let stackView = self as? UIStackView {
            views.forEach { stackView.addArrangedSubview($0) }
        } else {
            views.forEach { addSubview($0) }
        }
        return self
    }

    @discardableResult
    func add(@AddViewBuilder _ block: () -> (UIView?)) -> UIView {
        guard let view = block() else { return self }
        if let stackView = self as? UIStackView {
            stackView.addArrangedSubview(view)
        } else {
            addSubview(view)
        }
        return self
    }
    
    @discardableResult
    func add(insets: UIEdgeInsets, _ block: () -> (UIView)) -> UIView {
        let view = block()
        add { view }
        NSLayoutConstraint.activate {
            self.topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top)
            self.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left)
            self.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.right)
            self.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -insets.bottom)
        }
        return self
    }

    @discardableResult
    func insert(at index: Int, _ block: () -> (UIView)) -> UIView {
        if let stackView = self as? UIStackView {
            stackView.insertArrangedSubview(block(), at: index)
        } else {
            insertSubview(block(), at: index)
        }
        return self
    }
    
    // MARK: - Animation
    
    func animateScale(isHighlighted: Bool, scale: CGFloat, animationDuration: TimeInterval) {
        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        let toValue = isHighlighted
            ? CATransform3DMakeScale(scale, scale, 1)
            : CATransform3DMakeScale(1, 1, 1)
        var fromValue: CATransform3D
        var duration: TimeInterval
        
        // If we are already animating:
        //  - start from current value
        //  - if state has changed, go in different direction
        //  - adjust timing accordingly(i.e. get from current state time needed to finish)
        if let presentationLayer = self.layer.presentation() {
            // m11(or diagonal elements?) represents current scale
            let currentProgressOfAnimation = (presentationLayer.transform.m11 - scale) / (1 - scale)
            duration = isHighlighted
                ? animationDuration * Double(currentProgressOfAnimation)
                : animationDuration * (1 - Double(currentProgressOfAnimation))
            fromValue = presentationLayer.transform
        } else {
            duration = animationDuration
            fromValue = self.layer.transform
        }

        scaleAnimation.toValue = toValue
        scaleAnimation.duration = duration
        scaleAnimation.fromValue = fromValue
        
        CATransaction.begin()
        self.layer.removeAnimation(forKey: "highlightingScale")
        self.layer.add(scaleAnimation, forKey: "highlightingScale")
        CATransaction.setCompletionBlock {
            self.layer.transform = toValue
        }
        CATransaction.commit()
    }
}
