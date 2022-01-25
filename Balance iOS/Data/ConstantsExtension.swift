import Foundation
import Constants

extension Constants {
    
    enum Bundles {
        
        static var app: String { "io.balance" }
    }
    
    enum Scenes {
        
        static var root: String { "Root Scene" }
        static var settings: String { "Settings Scene" }
    }
    
    enum UserActivities {
        
        static var show_settings: String {  Constants.Bundles.app + ".showSettings" }
    }
}
