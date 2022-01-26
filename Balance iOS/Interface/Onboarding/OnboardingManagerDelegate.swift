import Foundation
import UIKit

protocol OnboardingManagerDelegate: AnyObject {
    
    func onboardingActionComplete(for controller: UIViewController)
}
