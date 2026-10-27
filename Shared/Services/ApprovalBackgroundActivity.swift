import WalletFlows
import WalletAuthority

#if os(iOS) || os(visionOS)
import UIKit

enum ApprovalBackgroundActivity {
    @available(iOSApplicationExtension, unavailable)
    @available(visionOSApplicationExtension, unavailable)
    nonisolated static func make(using application: UIApplication) -> AuthorityRuntime.BackgroundTask {
        { expiration in
            let identifier = application.beginBackgroundTask(
                withName: "Publish Safari approval vault",
                expirationHandler: expiration
            )
            guard identifier != .invalid else { return nil }
            return { application.endBackgroundTask(identifier) }
        }
    }
}
#endif
