import UIKit
import Constants

class SceneUserActivity: NSUserActivity {
    
    let action: Action
    
    init(_ action: Action) {
        self.action = action
        super.init(activityType: action.id)
        /*switch action {
        case .showExpenseDetail(let expenseID):
            userInfo = [Constants.UserActivities.UserInfoKeys.expense_id_key : expenseID]
        default:
            break
        }*/
    }
    
    var scene: UISceneConfiguration.Scene {
        switch action {
        case .showSettings:
            return .settings
        }
    }
    
    // MARK: - Models
    
    enum Action {
        
        case showSettings
        
        fileprivate var id: String {
            switch self {
            case .showSettings: return Constants.UserActivities.show_settings
            }
        }
    }
}
