// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import UIKit
import Combine

final class AccountsListImageView: CachingImageView {
    
    override func loadImage(for identifier: String) -> AnyPublisher<UIImage?, Never> {
        return Just(identifier)
        .flatMap({ poster -> AnyPublisher<UIImage?, Never> in
            let url = URL(string: "https://edservices.wiley.com/wp-content/uploads/2018/06/Moderating-Loarge-Online-Courses-On-page-larger-1.jpg")!
            return ServiceLayer.Services.images.loadRemoteImage(from: url)
        })
        .eraseToAnyPublisher()
//        ServiceLayer.Services.images.loadRemoteImage(from: <#T##URL#>)
//        let privateKeyChainType = wallet.associatedMetadata.privateKeyChain
        
//        ImageLoader.shared.loadImage(
//            walletId: String,
//            imageComputeClosure: {
//                let icon: UIImage?
//                if wallet.isMnemonic {
//                    if wallet.associatedMetadata.allChains.contains(.ethereum) {
//                        icon = Blockies(
//                            seed: wallet[.ethereum, .address]??.lowercased(), size: 10
//                        ).createImage()
//                    } else {
//                        icon = UIImage() // go for wallet
//                    }
//                } else {
//                    if privateKeyChainType == .ethereum {
//                        icon = Blockies(
//                            seed: wallet[.address]??.lowercased(), size: 10
//                        ).createImage()
//                    } else {
//                        icon = UIImage() // go for wallet
//                    }
//                }
//                return icon
//            },
//            fallbackImage: {
//                UIImage(named: "multiChainGrid")!
//            }
//        )
    }
}
