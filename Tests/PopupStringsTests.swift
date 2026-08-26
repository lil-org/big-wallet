// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

// The popup's chrome is HTML, so these keys are a contract with the `data-string` attributes in
// popup.html and the `localized(...)` calls in popup.js. Both sides are read straight off disk:
// a hand-copied list here would pass while the popup rendered a raw key.
final class PopupStringsTests: XCTestCase {

    private let reviewToken = "00000000-0000-4000-8000-000000000092"

    private func popupRequest(
        subject: InternalSafariRequest.Subject.Popup,
        payload: Any,
        id: Int = 91
    ) throws -> InternalSafariRequest {
        var message: [String: Any] = [
            "id": id,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "subject": subject.rawValue,
            "requestToken": "00000000-0000-4000-8000-000000000091",
            "payload": payload,
        ]
        if subject != .getApprovalState && subject != .getPendingRequests {
            message["reviewToken"] = "00000000-0000-4000-8000-000000000092"
        }
        let data = try JSONSerialization.data(withJSONObject: message)
        return try JSONDecoder().decode(InternalSafariRequest.self, from: data)
    }

    private func approvalStateRequest(id: Int = 91) throws -> InternalSafariRequest {
        return try popupRequest(
            subject: .getApprovalState,
            payload: ["mode": "full"],
            id: id
        )
    }

    private func oversizedResponse(
        state: String,
        canReject: Bool? = nil,
        reviewToken: String? = "00000000-0000-4000-8000-000000000092"
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": 91,
            "state": state,
            "kind": "signMessage",
            "host": "wallet.example",
            "meta": String(
                repeating: "x",
                count: PopupApprovalStatePresenter.maximumResponseBytes
            ),
        ]
        response["canReject"] = canReject
        response["reviewToken"] = reviewToken
        return response
    }

    private func resource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Safari Shared/Resources/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func localizableCatalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Supporting Files/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func matches(_ pattern: String, in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var keys = Set<String>()
        for match in expression.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            keys.insert(String(text[keyRange]))
        }
        return keys
    }

    func testPopupStringsCoverEveryChromeKey() throws {
        let markupKeys = try matches("data-string=\"([^\"]+)\"", in: resource("popup.html"))
        let scriptKeys = try matches("localized\\(\"([^\"]+)\"", in: resource("popup.js"))
        XCTAssertFalse(markupKeys.isEmpty)
        XCTAssertFalse(scriptKeys.isEmpty)
        XCTAssertEqual(Set(Strings.popup.keys), markupKeys.union(scriptKeys))
    }

    func testPopupStringsAreNeverEmpty() {
        for (key, value) in Strings.popup {
            XCTAssertFalse(value.isEmpty, "empty popup string for \(key)")
        }
    }

    func testSafetyStringsCoverEveryCatalogLocale() throws {
        let catalog = try localizableCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let supportedLocales = strings.values.reduce(into: Set<String>()) {
            locales, entry in
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                return
            }
            locales.formUnion(localizations.keys)
        }
        XCTAssertFalse(supportedLocales.isEmpty)

        for key in [
            "Big Wallet requests are unavailable in Private Browsing.",
            "Transaction submission status is unknown. Check the transaction ID before trying again.",
        ] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for (locale, localization) in localizations {
                let localization = try XCTUnwrap(
                    localization as? [String: Any],
                    "\(key) [\(locale)]"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) [\(locale)]"
                )
                XCTAssertEqual(
                    stringUnit["state"] as? String,
                    "translated",
                    "\(key) [\(locale)]"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "\(key) [\(locale)]"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key) [\(locale)]"
                )
            }
        }
    }

    func testCompactApprovalErrorHasExactRefreshOnlyShape() {
        let error = PopupApprovalStatePresenter.compactError(
            id: 91,
            host: "wallet.example",
            error: Strings.failedToLoad
        )

        XCTAssertEqual(Set(error.keys), ["id", "state", "host", "error"])
        XCTAssertEqual(error["state"] as? String, "error")
        XCTAssertEqual(error["error"] as? String, Strings.failedToLoad)
        XCTAssertNil(error["reviewToken"])
        XCTAssertNil(error["canReject"])
    }

    func testCompactRejectableErrorHasExactRejectOnlyShape() {
        let error = PopupApprovalStatePresenter.compactRejectableError(
            id: 91,
            host: "wallet.example",
            error: Strings.failedToLoad
        )

        XCTAssertEqual(
            Set(error.keys),
            ["id", "state", "host", "error", "canReject"]
        )
        XCTAssertEqual(error["state"] as? String, "working")
        XCTAssertNil(error["reviewToken"])
        XCTAssertEqual(error["canReject"] as? Bool, true)
    }

    func testQueuePositionKeepsBothPositionalSpecifiers() {
        let template = Strings.popup["queuePosition"]
        XCTAssertEqual(template?.contains("%1$@"), true)
        XCTAssertEqual(template?.contains("%2$@"), true)
    }

    func testGweiUnitsRideAlongWithTheFeeLabels() {
        for key in ["gasPrice", "maxPriorityFee", "maxFee"] {
            XCTAssertEqual(Strings.popup[key]?.hasSuffix("(\(Strings.gwei))"), true, key)
        }
    }

    @MainActor
    func testMoreThan256AccountAndNetworkChoicesRemainExactWhenTheyFit() throws {
        let choiceCount = 300
        let accounts = (0..<choiceCount).map { index in
            return [
                "walletId": "00000000-0000-4000-8000-000000000000-\(index)",
                "address": "0x" + String(format: "%040x", index),
                "coin": "ethereum",
                "name": "Account \(index)",
                "croppedAddress": "0000...0000",
                "isSelected": false,
            ] as [String: Any]
        }
        let networks = (0..<choiceCount).map { index in
            return [
                "chainId": "0x" + String(index + 1, radix: 16),
                "name": "Network \(index)",
                "isCustom": true,
                "isSelected": index == choiceCount - 1,
            ] as [String: Any]
        }
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "kind": "selectAccount",
            "host": "wallet.example",
            "reviewToken": reviewToken,
            "accounts": accounts,
            "networks": networks,
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual((bounded["accounts"] as? [[String: Any]])?.count, choiceCount)
        XCTAssertEqual((bounded["networks"] as? [[String: Any]])?.count, choiceCount)
        XCTAssertEqual(
            (bounded["accounts"] as? [[String: Any]])?.last?["name"] as? String,
            "Account 299"
        )
        XCTAssertEqual(
            (bounded["networks"] as? [[String: Any]])?.last?["name"] as? String,
            "Network 299"
        )
        XCTAssertLessThanOrEqual(
            try JSONSerialization.data(withJSONObject: bounded).count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testControlHeavySelectionBecomesAtomicFallbackWithoutShorteningLabels() throws {
        let displayName = String(repeating: "\u{0000}", count: 256)
        let accounts = (0..<256).map { index in
            return [
                "walletId": "00000000-0000-4000-8000-000000000000-\(index)",
                "address": "0x" + String(format: "%040x", index),
                "coin": "ethereum",
                "name": displayName,
                "croppedAddress": "0000...0000",
                "isSelected": false,
            ] as [String: Any]
        }
        let networks = (0..<256).map { index in
            return [
                "chainId": "0x" + String(index + 1, radix: 16),
                "name": displayName,
                "isCustom": true,
                "isSelected": false,
            ] as [String: Any]
        }
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "kind": "selectAccount",
            "host": "wallet.example",
            "reviewToken": reviewToken,
            "accounts": accounts,
            "networks": networks,
        ]

        XCTAssertEqual((response["accounts"] as? [[String: Any]])?.first?["name"] as? String, displayName)
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
        XCTAssertNil(bounded["kind"])
        XCTAssertNil(bounded["accounts"])
        XCTAssertNil(bounded["networks"])
        XCTAssertLessThanOrEqual(
            try JSONSerialization.data(withJSONObject: bounded).count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testOversizedSelectionReturnsAtomicRejectOnlyFallback() throws {
        let accounts = (0..<4_000).map { index in
            return [
                "walletId": "00000000-0000-4000-8000-000000000000-\(index)",
                "address": "0x" + String(format: "%040x", index),
                "coin": "ethereum",
                "name": "Account \(index)",
                "croppedAddress": "0000...0000",
                "isSelected": false,
            ] as [String: Any]
        }
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "kind": "selectAccount",
            "host": "wallet.example",
            "reviewToken": reviewToken,
            "accounts": accounts,
            "networks": [[String: Any]](),
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
        XCTAssertNil(bounded["kind"])
        XCTAssertNil(bounded["accounts"])
        XCTAssertNil(bounded["networks"])
    }

    @MainActor
    func testInvalidSelectionJSONUsesGenericFallback() throws {
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "kind": "selectAccount",
            "host": "wallet.example",
            "accounts": [["invalid": Date()]],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
    }

    @MainActor
    func testLongAddChainNameRemainsExactWhenResponseFits() throws {
        let chainName = String(repeating: "Network ", count: 100) + "exact suffix"
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "kind": "addChain",
            "host": "wallet.example",
            "chainName": chainName,
            "rpcURL": "https://rpc.example",
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["chainName"] as? String, chainName)
        XCTAssertEqual(bounded["kind"] as? String, "addChain")
    }

    @MainActor
    func testPopupResponseDropsDecorativeImagesBeforeFailingClosed() throws {
        let icon = "data:image/png;base64," + String(
            repeating: "A",
            count: PopupApprovalStatePresenter.maximumResponseBytes
        )
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "kind": "selectAccount",
            "host": "wallet.example",
            "iconURL": icon,
            "accounts": [[
                "name": "Account",
                "croppedAddress": "0000...0000",
                "icon": icon,
            ]],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )
        let accounts = try XCTUnwrap(bounded["accounts"] as? [[String: Any]])

        XCTAssertNil(bounded["iconURL"])
        XCTAssertNil(accounts.first?["icon"])
        XCTAssertEqual(bounded["kind"] as? String, "selectAccount")
        let data = try JSONSerialization.data(withJSONObject: bounded)
        XCTAssertLessThanOrEqual(
            data.count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testOversizedPopupResponseBecomesRejectOnlyErrorWithoutTruncation() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "review"),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["id"] as? Int, 91)
        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertEqual(bounded["host"] as? String, "wallet.example")
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["meta"])
    }

    @MainActor
    func testOversizedNonReviewResponseBecomesNonRejectableError() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "authenticating"),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["id"] as? Int, 91)
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["host"] as? String, "wallet.example")
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["canReject"])
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertNil(bounded["meta"])
    }

    @MainActor
    func testOversizedResponsePreservesExistingRejectionCapability() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "working", canReject: true),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
    }

    @MainActor
    func testOversizedHostCannotOverflowCompactResponse() throws {
        var response = oversizedResponse(state: "review")
        response["host"] = String(
            repeating: "h",
            count: PopupApprovalStatePresenter.maximumResponseBytes
        )

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertNil(bounded["host"])
        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
        let data = try JSONSerialization.data(withJSONObject: bounded)
        XCTAssertLessThanOrEqual(
            data.count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testOversizedMutationResponsesUseCompactApprovalState() throws {
        let requests = try [
            popupRequest(
                subject: .setTransactionSpeed,
                payload: ["interaction": "ended", "value": 0.5]
            ),
            popupRequest(
                subject: .applyTransactionEdits,
                payload: ["mode": "suggested"]
            ),
            popupRequest(
                subject: .resolveApprovalAlert,
                payload: ["action": "cancel"]
            ),
        ]

        for request in requests {
            let bounded = PopupApprovalStatePresenter.boundedResponse(
                oversizedResponse(state: "review"),
                for: request
            )
            XCTAssertEqual(bounded["id"] as? Int, 91)
            XCTAssertEqual(bounded["state"] as? String, "working")
            XCTAssertEqual(bounded["host"] as? String, "wallet.example")
            XCTAssertNil(bounded["reviewToken"])
            XCTAssertEqual(bounded["canReject"] as? Bool, true)
            XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
            XCTAssertNil(bounded["status"])
            XCTAssertNil(bounded["meta"])
        }
    }

    @MainActor
    func testStatusOnlySliderMutationIsRejectedByExactDecoder() {
        XCTAssertThrowsError(try popupRequest(
            subject: .setTransactionSpeed,
            payload: [
                "interaction": "moved",
                "value": 0.5,
                "responseMode": "status",
            ]
        ))
    }

    @MainActor
    func testOversizedReviewWithoutAuthoritativeTokenRemainsRejectable() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "review", reviewToken: nil),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
    }

    @MainActor
    func testOversizedReviewDoesNotExposeAuthoritativeToken() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(
                state: "review",
                reviewToken: reviewToken.uppercased()
            ),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "working")
        XCTAssertNil(bounded["reviewToken"])
        XCTAssertEqual(bounded["canReject"] as? Bool, true)
    }

}
