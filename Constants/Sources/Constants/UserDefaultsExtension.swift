import Foundation

extension UserDefaults {
    
    public static var local: UserDefaults {
        UserDefaults.standard
    }
    
    public static var shared: UserDefaults {
        UserDefaults.init(suiteName: Constants.app_group)!
    }
}
