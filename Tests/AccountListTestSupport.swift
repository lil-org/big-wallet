import AppKit
import XCTest
@testable import Big_Wallet

@MainActor
func accountSelectionWalletsManager() async throws -> WalletsManager {
    typealias Vectors = WalletCoreProxyTestVectors
    let key = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture))
    key.addAccountDerivation(
        address: Vectors.abandonEthereumSecondAddress,
        coin: .ethereum,
        derivation: .custom,
        derivationPath: "m/44'/60'/0'/0/1",
        publicKey: Vectors.abandonEthereumSecondPublicKey,
        extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey
    )
    key.addAccountDerivation(
        address: Vectors.solanaAddressFromPublicKey,
        coin: .solana,
        derivation: .custom,
        derivationPath: "m/44'/501'/0'",
        publicKey: Vectors.solanaAddressPublicKey,
        extendedPublicKey: ""
    )
    let reader = KeychainCopyMatchingStub()
    reader.attributes = [reader.walletAttributes(id: "selection-wallet")]
    reader.walletData = ["selection-wallet": try XCTUnwrap(key.exportJSON())]
    let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
    await assertWalletReload(manager)
    XCTAssertEqual(manager.wallets.first?.accounts.count, 3)
    return manager
}

@MainActor
func accountSelectionController(
    manager: WalletsManager,
    mode: NativeAccountSelectionMode,
    selectedAccounts: Set<SpecificWalletAccount>,
    coinType: WalletCoin? = nil,
    completion: @escaping ([SpecificWalletAccount]?, EthereumNetwork?) -> Void = { _, _ in }
) throws -> NativeAccountSelectionViewController {
    let session = NativeAccountSelectionSession(
        action: .init(coinType: coinType, selectedAccounts: selectedAccounts,
            initiallyConnectedProviders: [], network: Networks.ethereum),
        mode: mode, review: try nativeReviewForTesting(), completion: completion
    )
    let controller = NativeAccountSelectionViewController(accountSelection: session, walletsManager: manager)
    _ = controller.view
    return controller
}

@MainActor
func managementController(manager: WalletsManager) -> AccountsListViewController {
    let controller = AccountsListViewController()
    controller.walletsManager = manager
    _ = controller.view
    return controller
}

@MainActor
func accountSelectionWindow(controller: NSViewController) -> NSWindow {
    let window = NSPanel(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 400),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.orderFront(nil)
    controller.view.layoutSubtreeIfNeeded()
    return window
}

@MainActor
func pressDownArrow(in table: NSTableView, window: NSWindow) throws {
    try pressKey("\u{f701}", keyCode: 125, in: table, window: window)
}

@MainActor
func pressKey(
    _ characters: String,
    keyCode: UInt16,
    in table: NSTableView,
    window: NSWindow,
    isRepeat: Bool = false
) throws {
    XCTAssertTrue(window.firstResponder === table)
    let down = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: isRepeat,
        keyCode: keyCode
    ))
    NSApp.postEvent(down, atStart: true)
    let keyEvent = try XCTUnwrap(NSApp.nextEvent(
        matching: .keyDown,
        until: Date(timeIntervalSinceNow: 1),
        inMode: .default,
        dequeue: true
    ))
    window.sendEvent(keyEvent)
}

@MainActor
func clickAccountRow(
    _ row: Int,
    endingAt endRow: Int? = nil,
    in table: RightClickTableView,
    window: NSWindow,
    targetWindowOnly: Bool = false
) throws {
    let rowRect = table.rect(ofRow: row)
    let point = table.convert(NSPoint(x: rowRect.minX + 10, y: rowRect.midY), to: nil)
    let endRect = table.rect(ofRow: endRow ?? row)
    let endPoint = table.convert(NSPoint(x: endRect.minX + 10, y: endRect.midY), to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = try XCTUnwrap(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ))
    let up = try XCTUnwrap(NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: endPoint,
        modifierFlags: [],
        timestamp: timestamp + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    ))
    NSApp.postEvent(up, atStart: true)
    if endRow != nil {
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.005,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        NSApp.postEvent(drag, atStart: true)
    }
    NSApp.postEvent(down, atStart: true)
    let mouseEvent = try XCTUnwrap(NSApp.nextEvent(
        matching: .leftMouseDown,
        until: Date(timeIntervalSinceNow: 1),
        inMode: .default,
        dequeue: true
    ))
    if endRow != nil {
        table.mouseDown(with: mouseEvent)
    } else if targetWindowOnly {
        window.sendEvent(mouseEvent)
    } else {
        NSApp.sendEvent(mouseEvent)
    }
    if !targetWindowOnly {
        let deadline = Date(timeIntervalSinceNow: 0.05)
        while Date() < deadline,
              let event = NSApp.nextEvent(
                matching: .any,
                until: deadline,
                inMode: .default,
                dequeue: true
              ) {
            NSApp.sendEvent(event)
        }
        return
    }
    let remainingMouseEvents: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
    while let pending = NSApp.nextEvent(
        matching: remainingMouseEvents,
        until: .distantPast,
        inMode: .default,
        dequeue: false
    ), pending.windowNumber == window.windowNumber {
        guard let event = NSApp.nextEvent(
            matching: remainingMouseEvents,
            until: .distantPast,
            inMode: .default,
            dequeue: true
        ) else { break }
        window.sendEvent(event)
    }
}

final class TrackingMenu: NSMenu {
    private(set) var cancellationCount = 0

    override func cancelTrackingWithoutAnimation() {
        cancellationCount += 1
    }
}

final class PopupRecordingMenu: NSMenu {
    var onPopup: (() -> Void)?

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        MainActor.preconditionIsolated()
        onPopup?()
        let selector = #selector(NSMenuDelegate.menuDidClose(_:))
        if let delegate, delegate.responds(to: selector) {
            _ = delegate.perform(selector, with: self)
        }
        return false
    }
}
