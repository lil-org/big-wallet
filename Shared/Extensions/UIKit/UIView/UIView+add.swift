// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

@resultBuilder
public struct AddViewBuilder {
    public static func buildBlock(_ views: UIView...) -> [UIView] { views }

    public static func buildBlock(_ views: [UIView]) -> [UIView] { views }

    public static func buildBlock(_ view: UIView?) -> [UIView] {
        guard let view = view else { return [] }
        return [view]
    }
}

extension UIView {
    @discardableResult
    public func add(@AddViewBuilder _ block: () -> ([UIView])) -> UIView {
        if let stackView = self as? UIStackView {
            block().forEach { stackView.addArrangedSubview($0) }
        } else {
            block().forEach { addSubview($0) }
        }
        return self
    }

    @discardableResult
    public func add(_ views: [UIView]) -> UIView {
        if let stackView = self as? UIStackView {
            views.forEach { stackView.addArrangedSubview($0) }
        } else {
            views.forEach { addSubview($0) }
        }
        return self
    }

    @discardableResult
    public func add(@AddViewBuilder _ block: () -> (UIView?)) -> UIView {
        guard let view = block() else { return self }
        if let stackView = self as? UIStackView {
            stackView.addArrangedSubview(view)
        } else {
            addSubview(view)
        }
        return self
    }
    
    @discardableResult
    public func add(insets: UIEdgeInsets, _ block: () -> (UIView)) -> UIView {
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

    @discardableResult public func insert(at index: Int, _ block: () -> (UIView)) -> UIView {
        if let stackView = self as? UIStackView {
            stackView.insertArrangedSubview(block(), at: index)
        } else {
            insertSubview(block(), at: index)
        }
        return self
    }
}
