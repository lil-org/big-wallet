// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

protocol Configurable {
    associatedtype ViewModel
    func configure(with viewModel: ViewModel)
}
