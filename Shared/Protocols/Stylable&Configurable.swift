// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

public protocol Configurable {
    associatedtype ViewModel
    func configure(with viewModel: ViewModel)
}

public protocol StyleSettable {
    associatedtype StyleModel
    func style(with styleModel: StyleModel)
}

public protocol StyleAvailable {
    associatedtype StyleModel
    var style: StyleModel { get }
}
