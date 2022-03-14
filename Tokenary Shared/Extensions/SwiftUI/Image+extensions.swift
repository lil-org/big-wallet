// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
#if canImport(UIKit)
    import UIKit
    public typealias BridgedImage = UIImage
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    public typealias BridgedImage = NSImage
#endif

extension Image {
    public init(packageResource name: String, ofType type: String) {
#if canImport(UIKit)
        guard let path = Bundle.main.path(forResource: name, ofType: type),
              let image = UIImage(contentsOfFile: path) else {
            self.init(name)
            return
        }
        self.init(uiImage: image)
#elseif canImport(AppKit)
        guard let path = Bundle.main.path(forResource: name, ofType: type),
              let image = NSImage(contentsOfFile: path) else {
            self.init(name)
            return
        }
        self.init(nsImage: image)
#endif
    }
    
    public init(_ name: String, defaultImage: String) {
#if canImport(UIKit)
        guard let img = UIImage(named: name) else {
            self.init(defaultImage)
            return
        }
        self.init(uiImage: img)
#elseif canImport(AppKit)
        guard let img = NSImage(named: name) else {
            self.init(defaultImage)
            return
        }
        self.init(nsImage: img)
#endif
    }
        
    public init(_ name: String, defaultSystemImage: String) {
#if canImport(UIKit)
        if let img = UIImage(named: name) {
            self.init(uiImage: img)
            return
        }
#elseif canImport(AppKit)
        if let img = NSImage(named: name) {
            self.init(nsImage: img)
            return
        }
#endif
        self.init(systemName: defaultSystemImage)
    }
    
#if canImport(UIKit)
    public init(_ image: UIImage?, defaultImage: String) {
        if let image = image {
            self.init(uiImage: image)
        } else {
            self.init(defaultImage)
        }
    }
#elseif canImport(AppKit)
    public init(_ image: NSImage?, defaultImage: String) {
        if let image = image {
            self.init(nsImage: image)
        } else {
            self.init(defaultImage)
        }
    }
#endif
}

extension BridgedImage {
    /// As per https://stackoverflow.com/questions/26330924/get-average-color-of-uiimage-in-swift
    public var averageColor: BridgedColor? {
#if canImport(AppKit)
        guard !self.isValid else { return nil }
#endif
        
#if canImport(UIKit)
        guard let cgImageRef = self.cgImage else { return nil }
#elseif canImport(AppKit)
        var imageRect = CGRect(
            x: 0,
            y: 0,
            width: self.size.width,
            height: self.size.height
        )
        guard let cgImageRef = self.cgImage(
            forProposedRect: &imageRect, context: nil, hints: nil
        ) else { return nil }
#endif
        
        let inputImage = CIImage(cgImage: cgImageRef)
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ) else { return nil }
        guard let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return BridgedColor(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: CGFloat(bitmap[3]) / 255
        )
    }
}
