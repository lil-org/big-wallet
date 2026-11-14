import Foundation
import WalletAuthority
import WalletDomain
import WalletFlows

func nativeAdmissionContract(
    gate: NativeIngressGate,
    dispatcher: NativeMessageDispatcher,
    raw: Any,
    profileIdentifier: UUID?
) async throws -> WireProtocol.ValidatedObject {
    let admission = try gate.admit(raw, profileIdentifier: profileIdentifier)
    defer { admission.finish() }
    let _: Int = admission.id
    let _: NativeRequestContext = admission.context
    return try await dispatcher.dispatch(admission)
}
