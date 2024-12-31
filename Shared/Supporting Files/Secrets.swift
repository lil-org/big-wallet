// ∅ 2025 lil org

import Foundation

struct Secrets {
    
    static let infuraKey: String? = {
        if let key = plist["InfuraKey"] as? String, !key.isEmpty {
            return key
        } else {
            return nil
        }
    }()
    
    private static let plist: [String: AnyObject] = {
        let path = Bundle.main.path(forResource: "Secrets", ofType: "plist")!
        let dict = NSDictionary(contentsOfFile: path) as! [String: AnyObject]
        return dict
    }()
    
}
