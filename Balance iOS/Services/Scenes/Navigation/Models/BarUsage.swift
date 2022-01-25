import UIKit

enum BarUsage: String {
    
    case tabBar
    case sideBar
    
    var allowCacheControllers: Bool {
        switch self {
        case .tabBar: return false
        case .sideBar: return true
        }
    }
    
    var id: String { return rawValue }
}
