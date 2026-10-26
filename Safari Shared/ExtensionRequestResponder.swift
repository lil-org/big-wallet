import Foundation
import Synchronization
import WalletDomain

final class ExtensionRequestResponder: Sendable {
    private let context: Mutex<NSExtensionContext?>

    init(context: sending NSExtensionContext) {
        self.context = Mutex(context)
    }

    func cancelRequest(withError error: Error) {
        context.withLock { context in
            guard let current = context else { return }
            context = nil
            current.cancelRequest(withError: error)
        }
    }

    func complete(with response: WireProtocol.ValidatedObject) {
        context.withLock { context in
            guard let current = context else { return }
            context = nil
            let item = NSExtensionItem()
            item.userInfo = ["message": response.json]
            current.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
