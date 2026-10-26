import Foundation
import WalletDomain
import WalletAuthority

extension NativeAgentLauncher.Dependencies {
    static func live(runtimeIdentityDirectoryURL: URL?) -> Self {
        Self(
            helperURL: NativeAgentRuntime.embeddedHelperURL,
            validate: NativeAgentRuntime.validateEmbeddedHelper,
            helpers: {
#if os(macOS)
                NativeAgentRuntime.runningHelpers()
#else
                []
#endif
            },
            helper: { identifier in
#if os(macOS)
                NativeAgentRuntime.runningHelper(processIdentifier: identifier)
#else
                nil
#endif
            },
            identity: { AmbientRuntimeIdentity.load(processIdentifier: $0, directoryURL: runtimeIdentityDirectoryURL) },
            launch: { target, routeURL in
                await NativeAgentRuntime.launchApplication(
                    target: target, routeURL: routeURL, runtimeIdentityDirectoryURL: runtimeIdentityDirectoryURL
                )
            },
            uptime: { DispatchTime.now().uptimeNanoseconds },
            sleepUntil: { deadline in
                let now = DispatchTime.now().uptimeNanoseconds
                guard deadline > now else { return }
                try? await Task.sleep(nanoseconds: deadline - now)
            }
        )
    }
}

@MainActor
extension NativeApprovalService.Dependencies {
    static func live(bridge: ExtensionBridge, runtimeIdentityDirectoryURL: URL?) -> Self {
        Self(
            launcher: NativeAgentLauncher(dependencies: .live(runtimeIdentityDirectoryURL: runtimeIdentityDirectoryURL)),
            load: { await bridge.load(handle: $0) },
            responseStatus: {
                await bridge.responseStatus(
                    handle: $0, configurationKey: $1
                )
            },
            maintainProfile: {
                await bridge.performMaintenance(profileIdentifier: $0)
            },
            clearReceipt: { handle, receipt in
                await bridge.clearNativeDeliveryReceipt(
                    handle: handle,
                    nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                    runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
                )
            },
            uptime: { DispatchTime.now().uptimeNanoseconds },
            sleepUntil: { deadline in
                let now = DispatchTime.now().uptimeNanoseconds
                guard deadline > now else { return }
                try? await Task.sleep(nanoseconds: deadline - now)
            }
        )
    }
}
