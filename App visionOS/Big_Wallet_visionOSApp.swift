// ∅ 2025 lil org

import SwiftUI

let screenshotMode = false
var launchURL: URL?

@main
struct Big_Wallet_visionOSApp: App {
    
    @State private var showAccountsView = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if showAccountsView {
                    AccountsViewControllerWrapper()
                } else {
                    PasswordViewControllerWrapper(successHandler: {
                        DispatchQueue.main.async {
                            showAccountsView = true
                        }
                    })
                }
            }.onOpenURL { url in
                DispatchQueue.main.async {
                    launchURL = url
                    NotificationCenter.default.post(name: .receievedWalletRequest, object: nil)
                }
            }
        }
        .defaultSize(CGSize(width: 420, height: 555))
    }
}

struct PasswordViewControllerWrapper: UIViewControllerRepresentable {
    
    var successHandler: () -> Void
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = instantiate(PasswordViewController.self, from: .main)
        vc.showAccountsListOnVision = successHandler
        return vc.inNavigationController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct AccountsViewControllerWrapper: UIViewControllerRepresentable {
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = instantiate(AccountsListViewController.self, from: .main)
        return vc.inNavigationController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
