import WalletAuthority
import WalletDomain
import WalletFlows

func forbidden(
    dispatcher: NativeMessageDispatcher,
    message: WireProtocol.JSONObject,
    context: NativeRequestContext
) async throws {
    _ = try await dispatcher.dispatch(message: message, context: context)
}
