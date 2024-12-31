// ∅ 2025 lil org

import UIKit

enum Storyboard: String {
    case main
}

func instantiate<ViewController: UIViewController>(_ type: ViewController.Type, from storyboard: Storyboard) -> ViewController {
    return UIStoryboard(name: storyboard.rawValue.withFirstLetterCapitalized, bundle: nil).instantiateViewController(withIdentifier: String(describing: type)) as! ViewController
}
