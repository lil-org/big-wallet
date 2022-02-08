import Foundation
import Constants

extension Constants {
    
    static var intercom_key: String { "ios_sdk-58c8bebe9e93045233b86b57bb7f7d39551c444f" }
    static var intercom_app_id: String { "j0fl7v0m" }
    
    enum Bundles {
        
        static var app: String { "io.balance" }
        static var app_id: String { "1606612333" }
    }
    
    enum Scenes {
        
        static var root: String { "Root Scene" }
        static var settings: String { "Settings Scene" }
    }
    
    enum UserActivities {
        
        static var show_settings: String {  Constants.Bundles.app + ".showSettings" }
    }
    
    enum _3D {
        
        enum Logo {
            
            static var scene_filename: String { "balance-logo.scn" }
            static var logo_node: String { "logo" }
        }
    }
}
