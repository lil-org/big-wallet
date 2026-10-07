import AppKit
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeSecretAlertPresentationTests: XCTestCase {
    func testNativeCopyActionRunsBeforeSheetIsDetached() async {
        let session = SecretPresentationSession()
        let token = session.begin()
        session.store("private-key", for: token)
        let owner = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        owner.isReleasedWhenClosed = false
        owner.alphaValue = 0
        let ended = expectation(description: "Native sheet ended")
        var copied = [String]()
        var didPresent = false
        var copyCheckedWhileSheetWasAttached = false
        weak var observedPresentation: NativeSecretAlertPresentation?
        let presentation = NativeSecretAlertPresentation(
            session: session,
            token: token,
            title: "Private key",
            canCopy: {
                guard didPresent else { return true }
                copyCheckedWhileSheetWasAttached = observedPresentation?.alert.window.sheetParent === owner
                return copyCheckedWhileSheetWasAttached
            },
            copy: { copied.append($0) },
            didEnd: { ended.fulfill() }
        )
        observedPresentation = presentation
        presentation.alert.window.alphaValue = 0
        defer {
            presentation.dismiss()
            owner.orderOut(nil)
        }

        presentation.present(for: owner)
        didPresent = true
        XCTAssertTrue(presentation.alert.window.sheetParent === owner)
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(
            nil, owner: owner, presentation: presentation
        ))
        presentation.alert.buttons[1].performClick(nil)
        await fulfillment(of: [ended], timeout: 2)

        XCTAssertEqual(copied, ["private-key"])
        XCTAssertTrue(copyCheckedWhileSheetWasAttached)
        XCTAssertEqual(presentation.secretField.stringValue, "")
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(
            nil, owner: owner, presentation: presentation
        ))
    }

    func testKeyWindowValidationRejectsStaleOwnershipAndUnrelatedWindows() {
        let session = SecretPresentationSession()
        let token = session.begin()
        let owner = ReportedKeyWindow()
        let unrelated = ReportedKeyWindow()
        let presentation = NativeSecretAlertPresentation(
            session: session,
            token: token,
            title: "Private key",
            canCopy: { true }
        )

        XCTAssertTrue(NativeSecretAlertPresentation.acceptsKeyWindow(
            owner, owner: owner, presentation: presentation
        ))
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(
            presentation.alert.window, owner: owner, presentation: presentation
        ))
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(
            unrelated, owner: owner, presentation: presentation
        ))
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(
            nil, owner: owner, presentation: presentation
        ))
        owner.reportsKey = false
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(
            owner, owner: owner, presentation: presentation
        ))
    }

    func testResignedSheetCannotUseStaleKeyWindowReferenceToCopy() {
        let session = SecretPresentationSession()
        let token = session.begin()
        session.store("private-key", for: token)
        let owner = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        owner.isReleasedWhenClosed = false
        owner.alphaValue = 0
        var copied = [String]()
        var didPresent = false
        weak var observedPresentation: NativeSecretAlertPresentation?
        let presentation = NativeSecretAlertPresentation(
            session: session, token: token, title: "Private key",
            canCopy: {
                guard didPresent else { return true }
                return NativeSecretAlertPresentation.acceptsKeyWindow(
                    observedPresentation?.alert.window, owner: owner, presentation: observedPresentation
                )
            },
            copy: { copied.append($0) }
        )
        observedPresentation = presentation
        presentation.alert.window.alphaValue = 0
        defer {
            presentation.dismiss()
            owner.orderOut(nil)
        }

        XCTAssertTrue(session.isCurrent(token))
        presentation.present(for: owner)
        didPresent = true
        XCTAssertTrue(presentation.alert.window.sheetParent === owner)
        presentation.alert.window.resignKey()
        XCTAssertFalse(presentation.alert.window.isKeyWindow)

        presentation.finish(.alertSecondButtonReturn)

        XCTAssertTrue(copied.isEmpty)
        XCTAssertNil(session.value(for: token))
        XCTAssertEqual(presentation.secretField.stringValue, "")
    }

    func testCopyClearsPresentationBeforeCopyingAndOnlyRunsOnce() {
        let session = SecretPresentationSession()
        let token = session.begin()
        session.store("private-key", for: token)
        var copied = [String]()
        var didEnd = false
        let presentation = NativeSecretAlertPresentation(
            session: session,
            token: token,
            title: "Private key",
            canCopy: { true },
            copy: { value in
                XCTAssertNil(session.value(for: token))
                XCTAssertTrue(didEnd)
                copied.append(value)
            },
            didEnd: { didEnd = true }
        )
        presentation.secretField.stringValue = "private-key"

        presentation.finish(.alertSecondButtonReturn)
        presentation.finish(.alertSecondButtonReturn)

        XCTAssertEqual(copied, ["private-key"])
        XCTAssertEqual(presentation.secretField.stringValue, "")
        XCTAssertEqual(presentation.alert.informativeText, "")
    }

    func testClosingAndAbortingNeverCopy() {
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .abort, .cancel, .init(rawValue: -7)] {
            let session = SecretPresentationSession()
            let token = session.begin()
            session.store("seed words", for: token)
            var copied = false
            let presentation = NativeSecretAlertPresentation(
                session: session,
                token: token,
                title: "Secret words",
                canCopy: { true },
                copy: { _ in copied = true }
            )
            presentation.secretField.stringValue = "seed words"

            presentation.finish(response)

            XCTAssertFalse(copied)
            XCTAssertFalse(session.isCurrent(token))
            XCTAssertEqual(presentation.secretField.stringValue, "")
        }
    }

    func testRevocationPreventsLateCopyCallback() {
        let session = SecretPresentationSession()
        let token = session.begin()
        session.store("private-key", for: token)
        var copied = false
        let presentation = NativeSecretAlertPresentation(
            session: session,
            token: token,
            title: "Private key",
            canCopy: { true },
            copy: { _ in copied = true }
        )

        presentation.dismiss()
        presentation.finish(.alertSecondButtonReturn)

        XCTAssertFalse(copied)
        XCTAssertNil(session.value(for: token))
    }

    func testObsoletePresentationCannotCopyOrInvalidateReplacement() {
        let session = SecretPresentationSession()
        let first = session.begin()
        session.store("old-secret", for: first)
        var copied = false
        let presentation = NativeSecretAlertPresentation(
            session: session,
            token: first,
            title: "Private key",
            canCopy: { true },
            copy: { _ in copied = true }
        )
        let replacement = session.begin()
        session.store("new-secret", for: replacement)

        presentation.finish(.alertSecondButtonReturn)

        XCTAssertFalse(copied)
        XCTAssertEqual(session.value(for: replacement), "new-secret")
    }

    func testInactiveOwnerCannotCopyAndDisplayDoesNotAllowUnprotectedCopying() {
        let session = SecretPresentationSession()
        let token = session.begin()
        session.store("private-key", for: token)
        var copied = false
        let presentation = NativeSecretAlertPresentation(
            session: session,
            token: token,
            title: "Private key",
            canCopy: { false },
            copy: { _ in copied = true }
        )

        presentation.finish(.alertSecondButtonReturn)

        XCTAssertFalse(copied)
        XCTAssertNil(session.value(for: token))
        XCTAssertFalse(presentation.secretField.isSelectable)
        XCTAssertFalse(presentation.secretField.isEditable)
    }
}

@MainActor
private final class ReportedKeyWindow: NSWindow {
    var reportsKey = true

    override var isKeyWindow: Bool { reportsKey }
}
