// Copyright © 2022 Tokenary. All rights reserved.
// Generate amazing quality QR-codes. Idea's courtesy of Tg.

import Foundation
import UIKit
import Combine

//  - Wrapper CGContext for handling resizing and setup functionality
//  - Generate QRCode using CIFilter
//  - Redraw on context, by hand
//  - Apply styling

enum QRCodeIcon {
    case none
    case custom(UIImage)
}

protocol QRCodeGeneratorService {
    func qrCode(
        for source: String, foregroundColor: UIColor?, backgroundColor: UIColor, icon: QRCodeIcon
    ) -> AnyPublisher<UIImage?, Never>
}

extension QRCodeGeneratorService {
    func qrCode(
        for source: String,
        foregroundColor: UIColor? = nil,
        backgroundColor: UIColor = .black,
        icon: QRCodeIcon = .none
    ) -> AnyPublisher<UIImage?, Never> {
        qrCode(for: source, foregroundColor: foregroundColor, backgroundColor: backgroundColor, icon: icon)
    }
}

final class QRCodeGeneratorServiceImp: QRCodeGeneratorService {
    func qrCode(
        for source: String, foregroundColor: UIColor?, backgroundColor: UIColor, icon: QRCodeIcon
    ) -> AnyPublisher<UIImage?, Never> {
        Just(nil).eraseToAnyPublisher()
    }
}
