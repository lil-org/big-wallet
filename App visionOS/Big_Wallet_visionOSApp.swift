import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import SwiftUI

let screenshotMode = false

@main
struct Big_Wallet_visionOSApp: App {
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAccountsView = false
    @State private var accountPresentationRequest = 0
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        ApplicationServices.shared.prewarm()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if isTestHost {
                    Color.clear
                } else if showAccountsView {
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
                guard !isTestHost else { return }
                await ApplicationServices.shared.wallets.start()
                guard !Task.isCancelled else { return }
                let backgroundTask = ApprovalBackgroundActivity.make(using: .shared)
                await ApplicationServices.shared.authority.startVaultReconciliation(backgroundTask: backgroundTask, protectedDataDidBecomeAvailable: UIApplication.protectedDataDidBecomeAvailableNotification)
            }
            .task(id: scenePhase) {
                guard !isTestHost, scenePhase == .active else { return }
                ApplicationServices.shared.prewarm()
                _ = await ApplicationServices.shared.wallets.reloadFromStore()
                guard !Task.isCancelled else { return }
                await ApplicationServices.shared.authority.reconcileVault()
                await ApplicationServices.shared.requests.performMaintenance()
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
