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
    
    enum _3D {
        
        enum Logo {
            
            static var scene_filename: String { "balance-logo.scn" }
            static var logo_node: String { "logo" }
        }
        
        enum Safari {
            
            static var scene_filename: String { "coin.scn" }
            static var logo_node: String { "logo" }
        }
    }
}
