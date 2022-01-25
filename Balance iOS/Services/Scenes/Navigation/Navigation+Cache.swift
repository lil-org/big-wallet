import UIKit

extension Navigation {
    
    internal class Cache: NSObject {
        
        // MARK: - Data
        
        private var cachedControllers: [(id: String, controller: UIViewController)] = []
        
        // MARK: - Public
        
        static func getController(by id: String) -> UIViewController? {
            return shared.cachedControllers.first(where: { $0.id == id })?.controller
        }
        
        static func appendController(_ controller: UIViewController, for id: String) {
            shared.cachedControllers.append((id: id, controller: controller))
        }
        
        // MARK: - Singltine
        
        private static var shared = Cache()
        
        private override init() {
            super.init()
        }
    }
}
