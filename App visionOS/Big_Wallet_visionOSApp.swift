// ∅ 2026 lil org

import SwiftUI

let screenshotMode = false

@main
struct Big_Wallet_visionOSApp: App {
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAccountsView = false
    @State private var accountPresentationRequest = 0

    init() {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if showAccountsView {
                    AccountsViewControllerWrapper()
                } else {
                    PasswordViewControllerWrapper(successHandler: {
                        accountPresentationRequest += 1
                    })
                }
            }
            .task(id: accountPresentationRequest) {
                guard accountPresentationRequest > 0 else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                showAccountsView = true
            }
            .task {
                await WalletsManager.shared.start()
                guard !Task.isCancelled else { return }
                let backgroundTask = SafariApprovalVaultHost.backgroundTask(using: .shared)
                await SafariApprovalVaultHost.shared.start(backgroundTask: backgroundTask)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                AlchemyJWTProvider.prewarmForApplicationLifecycle()
                await WalletsManager.shared.handleExternalWalletStoreChange()
                guard !Task.isCancelled else { return }
                await SafariApprovalVaultHost.shared.reconcile()
                await ExtensionBridge.shared.performMaintenance()
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
