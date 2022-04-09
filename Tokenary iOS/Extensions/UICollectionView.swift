// Copyright © 2022 Tokenary. All rights reserved.
// Helper extensions for working with collection-views

import UIKit

extension UICollectionView {
    // MARK: - Dequeue

    public func dequeueReusableCell<T: UICollectionViewCell>(for indexPath: IndexPath) -> T {
        guard let wrappedView = dequeueReusableCell(
            withReuseIdentifier: String(describing: T.self), for: indexPath
        ) as? T else { preconditionFailure() }
        return wrappedView
    }
    
    // MARK: - Register

    public func registerCell<T: UICollectionViewCell>(class name: T.Type) {
        register(
            T.self,
            forCellWithReuseIdentifier: String(describing: name)
        )
    }
}
