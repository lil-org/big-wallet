import Foundation
import WalletDomain
import XCTest
@testable import Big_Wallet

final class NativeExtensionResponderTests: XCTestCase {
    func testExtensionRequestCompletesOrCancelsExactlyOnceAcrossTasks() async throws {
        let events = LockedTestValue([String]())
        let responder = ExtensionRequestResponder(context: RecordingExtensionContext(events: events))
        let response = try XCTUnwrap(WireProtocol.object(.nativeStatus, value: ["id": 1, "pending": true]))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        responder.complete(with: response)
                    } else {
                        responder.cancelRequest(withError: CocoaError(.userCancelled))
                    }
                }
            }
        }
        XCTAssertEqual(events.value.count, 1)
    }

}

private final class RecordingExtensionContext: NSExtensionContext {
    private let events: LockedTestValue<[String]>

    init(events: LockedTestValue<[String]>) {
        self.events = events
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func completeRequest(returningItems items: [Any]?, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        events.withValue { $0.append("completed") }
    }

    override func cancelRequest(withError error: Error) {
        events.withValue { $0.append("cancelled") }
    }
}
