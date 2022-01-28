import UIKit
import SparrowKit

enum Image {
    
    enum Safari {
        
        static var step_1: UIImage { .init(named: "safari-step-1")! }
        static var step_2: UIImage { .init(named: "safari-step-2")! }
        static var step_3: UIImage { .init(named: "safari-step-3")! }
    }
    
    static func language(for locale: SPLocale) -> UIImage {
        UIImage(named: locale.identifier) ?? UIImage()
    }
}
