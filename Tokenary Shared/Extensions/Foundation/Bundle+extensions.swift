// Copyright © 2021 Tokenary. All rights reserved.
// Helper extensions for `Bundle`

import Foundation

extension Bundle {
    
    /// All id's of modules
    public enum BundleId: String, CaseIterable {
        case helper = "io.Tokenary.tech.mobile.helper"
    }
    
    /// Get `Bundle` for `BundleId`
    public class func bundle(for bundleId: BundleId) -> Bundle {
        guard let bundle = Bundle(identifier: bundleId.rawValue) else {
            preconditionFailure("Bundle id with identifier '\(bundleId.rawValue)' not found!")
        }
        return bundle
    }
    
    public class func resourcesBundle(for object: AnyClass, with bundleName: String) -> Bundle? {
        guard let bundleURL = Bundle(for: object).resourceURL else { return nil }
        let resourcesBundleUrl = bundleURL.absoluteString.contains(FileExt.bundle.rawValue)
            ? bundleURL
            : bundleURL.appendingPathComponent(bundleName + Symbols.dot + FileExt.bundle.rawValue)
        return Bundle(url: resourcesBundleUrl)
    }
    
    var identifier: String {
        return infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    }
    
    var name: String {
        return infoDictionary?["CFBundleName"] as? String ?? ""
    }
    
    var shortVersionString: String {
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
