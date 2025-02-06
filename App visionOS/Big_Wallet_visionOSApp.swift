// ∅ 2025 lil org

import SwiftUI

let screenshotMode = false
var launchURL: URL?

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        launchURL = url
        didReceiveWalletRequest()
        return true
    }
    
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if let url = userActivity.webpageURL {
            launchURL = url
            didReceiveWalletRequest()
            return true
        }
        return false
    }
    
}

@main
struct Big_Wallet_visionOSApp: App {
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ViewControllerWrapper()
                .onOpenURL { url in
                    launchURL = url
                    didReceiveWalletRequest()
                }
        }
        .defaultSize(CGSize(width: 420, height: 555))
    }
    
}

struct ViewControllerWrapper: UIViewControllerRepresentable {
    
    func makeUIViewController(context: Context) -> UIViewController {
        return createInitialViewController()
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        
    }
    
}

func createInitialViewController() -> UIViewController {
    let vc = instantiate(PasswordViewController.self, from: .main)
    return vc.inNavigationController
}

func didReceiveWalletRequest() {
    // TODO: implement. i.e. ios version sends notif here
    // NotificationCenter.default.post(name: .receievedWalletRequest, object: nil)
    launchURL = nil
}
