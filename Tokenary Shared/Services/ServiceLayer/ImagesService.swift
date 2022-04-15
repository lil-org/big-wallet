// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import Combine
import UIKit
import BlockiesSwift

protocol ImagesService {
    func loadRemoteImage(from url: URL, force: Bool, skipCache: Bool) -> AnyPublisher<UIImage?, Never>
    func loadWalletImage(walletId: String, fallbackImage: UIImage) -> AnyPublisher<UIImage, Never>
}

extension ImagesService {
    func loadRemoteImage(from url: URL) -> AnyPublisher<UIImage?, Never> {
        loadRemoteImage(from: url, force: false, skipCache: false)
    }
}

final class ImagesServiceImp: ImagesService {
    
    private let cache: ImageCacheService
    private let operationsQueue: DispatchQueue
    
    init(operationsQueue: DispatchQueue, cache: ImageCacheService) {
        self.operationsQueue = operationsQueue
        self.cache = cache
    }

    func loadRemoteImage(from url: URL, force: Bool, skipCache: Bool) -> AnyPublisher<UIImage?, Never> {
        if !force {
            if let image = cache.image(forKey: url.path, having: .both) {
                return Just(image).eraseToAnyPublisher()
            }
        }
        return URLSession.shared.dataTaskPublisher(for: url)
            .map { (data, response) -> UIImage? in return UIImage(data: data) }
            .catch { error in return Just(nil) }
            .handleEvents(receiveOutput: { [unowned self] image in
                guard let image = image else { return }
                if !skipCache {
                    self.cache.cache(image: image, forKey: url.path, having: .both)
                }
            })
            .subscribe(on: self.operationsQueue)
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }
    
    func loadWalletImage(walletId: String, fallbackImage: UIImage) -> AnyPublisher<UIImage, Never> {
        Future<UIImage, Never> { promise in
            DispatchQueue.global().async {
                var icon: UIImage? = nil
                
                if let image = self.cache.image(forKey: walletId, having: .both) {
                    promise(.success(image))
                    return
                }
                
                if let ethAddress = WalletsManager.shared.getEthereumAddress(walletId: walletId) {
                    icon = Blockies(
                        seed: ethAddress.lowercased(), size: 10
                    ).createImage()
                }
                
                promise(.success(icon ?? fallbackImage))
            }
        }
        .handleEvents(receiveOutput: { [unowned self] image in
            self.cache.cache(image: image, forKey: walletId, having: .both)
        })
        .eraseToAnyPublisher()
    }
}
