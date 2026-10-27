import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import SwiftUI

let screenshotMode = false

@main
struct Big_Wallet_visionOSApp: App {
    
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        guard !isTestHost else { return }
        _ = MobileWalletSceneRegistry.shared
        ApplicationServices.shared.prewarm()
    }
    
    var body: some Scene {
        WindowGroup {
            if isTestHost { Color.clear }
            else { WalletSceneView(access: ApplicationServices.shared.access) }
        }
        .defaultSize(CGSize(width: 420, height: 555))

    }
}

private struct WalletSceneView: View {
    @Environment(\.scenePhase) private var scenePhase
    let access: WalletAccessController

    var body: some View {
        WalletRootControllerWrapper(access: access)
            .task {
                await ApplicationServices.shared.wallets.start()
                guard !Task.isCancelled else { return }
                let backgroundTask = ApprovalBackgroundActivity.make(using: .shared)
                await ApplicationServices.shared.authority.startVaultReconciliation(
                    backgroundTask: backgroundTask,
                    protectedDataDidBecomeAvailable: UIApplication.protectedDataDidBecomeAvailableNotification
                )
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                access.checkAccess()
                ApplicationServices.shared.prewarm()
                _ = await ApplicationServices.shared.wallets.reloadFromStore()
                guard !Task.isCancelled else { return }
                await ApplicationServices.shared.authority.reconcileVault()
                await ApplicationServices.shared.requests.performMaintenance()
            }
    }
}

private struct WalletRootControllerWrapper: UIViewControllerRepresentable {
    let access: WalletAccessController

    func makeUIViewController(context: Context) -> MobileWalletRootViewController {
        MobileWalletRootViewController(access: access)
    }

    func updateUIViewController(_ uiViewController: MobileWalletRootViewController, context: Context) {}
}
