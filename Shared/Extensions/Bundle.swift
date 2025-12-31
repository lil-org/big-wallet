// ∅ 2026 lil org

import Foundation

extension Bundle {

    private enum Keys {
        static let identifier = "CFBundleIdentifier"
        static let name = "CFBundleName"
        static let shortVersionString = "CFBundleShortVersionString"
    }

    var identifier: String {
        infoDictionary?[Keys.identifier] as? String ?? ""
    }

    var name: String {
        infoDictionary?[Keys.name] as? String ?? ""
    }

    var shortVersionString: String {
        infoDictionary?[Keys.shortVersionString] as? String ?? ""
    }
    
}
