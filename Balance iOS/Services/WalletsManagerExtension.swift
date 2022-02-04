import Foundation
import Constants
import SparrowKit
import UIKit
import SPAlert

extension WalletsManager {
    
    static func startDestroyProcess(on controller: UIViewController, sourceView: UIView, completion: @escaping (_ destroyed: Bool)->Void) {
        AlertService.confirm(
            title: Texts.Wallet.Destroy.confirm_title,
            description: Texts.Wallet.Destroy.confirm_description, actionTitle: Texts.Wallet.Destroy.action, desctructive: true, action: { confirmed in
                if confirmed {
                    completlyDestroyData()
                    completion(true)
                } else {
                    completion(false)
                }
            },
            sourceView: sourceView,
            presentOn: controller
        )
    }
    
    private static func completlyDestroyData() {
        do {
            try? WalletsManager.shared.destroy()
        }
        Keychain.shared.removePassword()
        Flags.seen_tutorial = false
        Flags.show_safari_extension_advice = true
        AppDelegate.migration()
        NotificationCenter.default.post(name: .walletsUpdated, object: nil)
    }
}
