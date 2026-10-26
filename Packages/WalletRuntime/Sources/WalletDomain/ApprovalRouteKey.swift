import Foundation

public struct ApprovalRouteKey: Hashable, Sendable {
    public let handle: RequestHandle
    public let nativeDeliveryNonce: NativeDeliveryNonce

    public init(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce) {
        self.handle = handle
        self.nativeDeliveryNonce = nativeDeliveryNonce
    }
}
