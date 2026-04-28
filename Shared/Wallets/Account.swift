// ∅ 2026 lil org

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import Cocoa
#endif
import WalletCore

struct WalletPreviewAccountKey: Hashable {
    let coin: CoinType
    let derivationPath: String
}

extension Account {

    var previewAccountKey: WalletPreviewAccountKey {
        return WalletPreviewAccountKey(coin: coin, derivationPath: derivationPath)
    }

    var previewDerivationIndex: Int {
        guard let path = DerivationPath(derivationPath) else { return 0 }
        switch coin {
        case .solana:
            return Int(path.account)
        default:
            return Int(path.address)
        }
    }

    var croppedAddress: String {
        let dropFirstCount: Int
        switch coin {
        case .ethereum:
            dropFirstCount = 2
        case .near, .solana:
            dropFirstCount = 0
        default:
            fatalError(Strings.somethingWentWrong)
        }
        let withoutCommonPart = String(address.dropFirst(dropFirstCount))
        return withoutCommonPart.prefix(4) + "..." + withoutCommonPart.suffix(4)
    }
    
    var image: PlatformSpecificImage? {
        switch coin {
        case .ethereum:
            return Blockies(seed: address.lowercased()).createImage()
        case .solana:
            return SolanaAccountIcon.image(seed: address, logo: Images.solana)
        default:
            return Images.circleFill
        }
    }
    
    func nameOrCroppedAddress(walletId: String) -> String {
        return WalletsMetadataService.getAccountName(walletId: walletId, account: self) ?? croppedAddress
    }
    
    func name(walletId: String) -> String? {
        return WalletsMetadataService.getAccountName(walletId: walletId, account: self)
    }
    
}

private enum SolanaAccountIcon {

    private static let canvasSize = CGSize(width: 32, height: 32)
    private static let logoMaxSize = CGSize(width: 15, height: 15)
    private static let logoAlpha: CGFloat = 0.82
    private static let imageCache = NSCache<NSString, PlatformSpecificImage>()
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private static let backgroundColorHexValues: [UInt32] = [
        0x4E6E8E, 0x3E7C78, 0x56796B, 0x6B6F4E, 0x7A6A45, 0x8A6252, 0x8B5E65,
        0x7A5F86, 0x5D6A9A, 0x4A789C, 0x3F7A92, 0x42766A, 0x61724D, 0x75664A,
        0x845B4F, 0x7B6474, 0x606B80, 0x516F75, 0x6A6F90, 0x4F7760, 0x6D667E
    ]

    static func image(seed: String, logo: PlatformSpecificImage) -> PlatformSpecificImage {
        let cacheKey = seed as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let image = makeImage(seed: seed, logo: logo)
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func makeImage(seed: String, logo: PlatformSpecificImage) -> PlatformSpecificImage {
        #if os(iOS) || os(visionOS)
        let format = UIGraphicsImageRendererFormat.default()

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in
            backgroundColor(seed: seed).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()

            let whiteLogo = logo.withTintColor(.white, renderingMode: .alwaysOriginal)
            whiteLogo.draw(in: logoRect(for: logo.size), blendMode: .normal, alpha: logoAlpha)
        }
        #elseif os(macOS)
        let image = NSImage(size: canvasSize)
        image.lockFocus()

        backgroundColor(seed: seed).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

        let whiteLogo = whiteLogoImage(from: logo)
        whiteLogo.draw(in: logoRect(for: logo.size),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: logoAlpha)

        image.unlockFocus()
        return image
        #endif
    }

    private static func logoRect(for logoSize: CGSize) -> CGRect {
        let scale = min(logoMaxSize.width / logoSize.width, logoMaxSize.height / logoSize.height)
        let size = CGSize(width: logoSize.width * scale, height: logoSize.height * scale)
        return CGRect(x: (canvasSize.width - size.width) / 2,
                      y: (canvasSize.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    private static func backgroundColor(seed: String) -> PlatformSpecificColor {
        color(hex: backgroundColorHexValues[colorIndex(seed: seed)])
    }

    private static func colorIndex(seed: String) -> Int {
        var hash = fnvOffsetBasis
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return Int(hash % UInt64(backgroundColorHexValues.count))
    }

    private static func color(hex: UInt32) -> PlatformSpecificColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return PlatformSpecificColor(red: red, green: green, blue: blue, alpha: 1)
    }

    #if os(macOS)
    private static func whiteLogoImage(from logo: NSImage) -> NSImage {
        let image = NSImage(size: logo.size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: logo.size)
        logo.draw(in: rect)
        NSColor.white.setFill()
        rect.fill(using: .sourceAtop)

        image.unlockFocus()
        return image
    }
    #endif

}

#if os(iOS) || os(visionOS)
private typealias PlatformSpecificColor = UIColor
#elseif os(macOS)
private typealias PlatformSpecificColor = NSColor
#endif
