// ∅ 2025 lil org

import SwiftUI

let screenshotMode = false
var launchURL: URL?

@main
struct Big_Wallet_visionOSApp: App {
    var body: some Scene {
        WindowGroup {
            ViewControllerWrapper()
        }.defaultSize(CGSize(width: 420, height: 555))
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
