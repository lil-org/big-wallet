// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit

protocol LayoutGroup {
    var constraints: [NSLayoutConstraint] { get }
}

extension NSLayoutConstraint: LayoutGroup {
    var constraints: [NSLayoutConstraint] { [self] }
}

extension Array: LayoutGroup where Element == NSLayoutConstraint {
    var constraints: [NSLayoutConstraint] { self }
}

@resultBuilder
struct AutoLayoutBuilder {
    static func buildBlock(_ components: LayoutGroup...) -> [NSLayoutConstraint] {
        return components.flatMap { $0.constraints }
    }
    
    static func buildOptional(_ component: [LayoutGroup]?) -> [NSLayoutConstraint] {
        return component?.flatMap { $0.constraints } ?? []
    }
    
    static func buildEither(first component: [LayoutGroup]) -> [NSLayoutConstraint] {
        return component.flatMap { $0.constraints }
    }

    static func buildEither(second component: [LayoutGroup]) -> [NSLayoutConstraint] {
        return component.flatMap { $0.constraints }
    }
}

extension NSLayoutConstraint {
     static func activate(@AutoLayoutBuilder constraints: () -> [NSLayoutConstraint]) {
         activate(constraints())
     }
}
