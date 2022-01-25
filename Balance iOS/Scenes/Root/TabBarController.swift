import UIKit
import SparrowKit

class TabBarController: UITabBarController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        Navigation.tabBars.forEach {
            addTabBarItem(with: $0.getController(), title: $0.title, image: $0.image)
        }
    }
}
