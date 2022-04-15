// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit
import Combine

final class AccountsListImageView: CachingImageView {
    override func loadImage(for identifier: String) -> AnyPublisher<UIImage, Never> {
        return Just(identifier)
        .flatMap { identifier -> AnyPublisher<UIImage, Never> in
            ServiceLayer.Services.images.loadWalletImage(
                walletId: identifier, fallbackImage: UIImage(named: "multiChainGrid")!
            )
        }
        .eraseToAnyPublisher()
    }
}
