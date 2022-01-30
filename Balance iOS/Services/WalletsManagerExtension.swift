import Foundation
import Constants
import SparrowKit
import UIKit
import SPAlert

extension WalletsManager {
    
    static func startDestroyProcess(on controller: UIViewController, sourceView: UIView) {
        AlertService.confirm(
            title: "Confirm destroy all data",
            description: "We will remove all connection of wallets and your password", actionTitle: "Destroy Now", desctructive: true, action: {
                SPAlert.present(title: "Wallet was reseted. Let's reconfigure it", message: nil, preset: .done, completion: {
                    WalletsManager.completlyDestroyData {
                        Presenter.App.showOnboarding(on: controller, afterAction: {
                            Presenter.Crypto.showWalletOnboarding(on: controller)
                            Flags.seen_tutorial = true
                        })
                    }
                })
            },
            sourceView: sourceView,
            presentOn: controller
        )
    }
    
    private static func completlyDestroyData(completion: ()->Void) {
        do {
            try? WalletsManager.shared.destroy()
        }
        Keychain.shared.removePassword()
        Flags.seen_tutorial = false
        Flags.show_safari_extension_advice = true
        NotificationCenter.default.post(name: .walletsUpdated, object: nil)
        completion()
    }
}
