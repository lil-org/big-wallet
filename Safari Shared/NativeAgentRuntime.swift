// ∅ 2026 lil org

import Foundation
import OSLog
import AppKit
import Security

enum NativeAgentRuntime {
    private static let logger = Logger(
        subsystem: "org.lil.wallet",
        category: "NativeAgentLauncher"
    )

    static func embeddedHelperURL() -> URL? {
#if os(macOS)
        return embeddedHelperURL(in: Bundle.main.bundleURL)
#else
        return nil
#endif
    }

    static func embeddedHelperURL(in extensionURL: URL) -> URL? {
        guard extensionURL.isFileURL,
              extensionURL.pathExtension == "appex" else { return nil }
        return extensionURL.standardizedFileURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("Big Wallet.app", isDirectory: true)
    }

    static func validateEmbeddedHelper(_ url: URL) async -> Bool {
#if os(macOS)
        return await codeValidator.validate(
            helperURL: url,
            extensionURL: Bundle.main.bundleURL
        )
#else
        return false
#endif
    }

#if os(macOS)
    private static let codeValidator = CodeValidator(
        validate: { checkEmbeddedHelper($0, extensionURL: $1) }
    )

    private static func checkEmbeddedHelper(_ url: URL, extensionURL: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "org.lil.wallet.ambient" else {
            logger.error("Helper bundle is unavailable")
            return false
        }
        guard let helperCode = staticCode(at: url) else {
            logger.error("Helper static code is unavailable")
            return false
        }
        guard let containingCode = staticCode(at: extensionURL) else {
            logger.error("Containing extension static code is unavailable")
            return false
        }
        let helperStatus = SecStaticCodeCheckValidity(
            helperCode,
            SecCSFlags(
                rawValue: kSecCSCheckAllArchitectures |
                    kSecCSCheckNestedCode |
                    kSecCSStrictValidate
            ),
            nil
        )
        let containingStatus = SecStaticCodeCheckValidity(
            containingCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard helperStatus == errSecSuccess, containingStatus == errSecSuccess else {
            logger.error("Code validation failed: helper=\(helperStatus) extension=\(containingStatus)")
            return false
        }
        let helperTeam = teamIdentifier(for: helperCode)
        let containingTeam = teamIdentifier(for: containingCode)
#if DEBUG
        return helperTeam == containingTeam
#else
        return helperTeam != nil && helperTeam == containingTeam
#endif
    }
#endif

    @MainActor
    static func launchApplication(
        target: NativeAgentLauncher.HelperTarget,
        routeURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
#if os(macOS)
        switch target {
        case .running(
            let helperURL,
            let processIdentifier,
            let runtimeInstanceIdentifier
        ):
            guard let version = AmbientRuntimeIdentity.bundleVersion(at: helperURL),
                  let processStartDate = AmbientRuntimeIdentity.processStartDate(
                      processIdentifier: processIdentifier
                  ),
                  let identity = AmbientRuntimeIdentity.load(processIdentifier: processIdentifier),
                  identity.matches(
                      processIdentifier: processIdentifier,
                      bundleURL: helperURL,
                      processStartDate: processStartDate
                  ), identity.instanceIdentifier == runtimeInstanceIdentifier,
                  identity.isCompatible(
                      withWorkflowVersion: ExtensionBridge.workflowVersion,
                      expectedVersion: version
                  ) else {
                completion(false)
                return
            }
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kInternetEventClass),
                eventID: AEEventID(kAEGetURL),
                targetDescriptor: NSAppleEventDescriptor(
                    processIdentifier: processIdentifier
                ),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(
                NSAppleEventDescriptor(string: routeURL.absoluteString),
                forKeyword: AEKeyword(keyDirectObject)
            )
            do {
                _ = try event.sendEvent(
                    options: [.noReply, .neverInteract],
                    timeout: 1
                )
                completion(true)
            } catch {
                logger.error("Helper route delivery failed: \((error as NSError).code)")
                completion(false)
            }
        case .launch(let helperURL):
            let configuration = applicationLaunchConfiguration()
            NSWorkspace.shared.open(
                [routeURL],
                withApplicationAt: helperURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    logger.error("Helper launch failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                }
                completion(error == nil)
            }
        }
#else
        completion(false)
#endif
    }

#if os(macOS)
    static func applicationLaunchConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = false
        return configuration
    }
#endif

#if os(macOS)
    static func runningHelpers() -> [NativeAgentLauncher.RuntimeHelper] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.lil.wallet.ambient"
        ).map(runtimeHelper)
    }

    static func runningHelper(processIdentifier: Int32) -> NativeAgentLauncher.RuntimeHelper? {
        NSRunningApplication(processIdentifier: processIdentifier).map(runtimeHelper)
    }

    private static func runtimeHelper(_ application: NSRunningApplication) -> NativeAgentLauncher.RuntimeHelper {
        let processIdentifier = application.processIdentifier
        let processStartDate = AmbientRuntimeIdentity.processStartDate(
            processIdentifier: processIdentifier
        )
        return NativeAgentLauncher.RuntimeHelper(
            processIdentifier: processIdentifier,
            bundleURL: application.bundleURL,
            processStartDate: processStartDate,
            isRunning: {
                runtimeProcessIsRunning(
                    processIdentifier: processIdentifier,
                    capturedStartDate: processStartDate,
                    isTerminated: application.isTerminated
                )
            },
            requestQuit: {
                requestExactReceiptOwnerQuit(
                    processIdentifier: processIdentifier,
                    capturedStartDate: processStartDate
                )
            }
        )
    }

    static func requestExactReceiptOwnerQuit(
        processIdentifier: Int32,
        capturedStartDate: Date?,
        runningProcessStartDate: (Int32) -> Date? = {
            AmbientRuntimeIdentity.processStartDate(processIdentifier: $0)
        },
        sendQuitEvent: (Int32) -> Bool = sendQuitAppleEvent
    ) -> Bool {
        switch AmbientRuntimeIdentity.processStatus(
            processIdentifier: processIdentifier,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: runningProcessStartDate
        ) {
        case .current:
            return sendQuitEvent(processIdentifier)
        case .replaced:
            return true
        case .unknown:
            return false
        }
    }

    static func runtimeProcessIsRunning(
        processIdentifier: Int32,
        capturedStartDate: Date?,
        isTerminated: Bool,
        runningProcessStartDate: (Int32) -> Date? = {
            AmbientRuntimeIdentity.processStartDate(processIdentifier: $0)
        }
    ) -> Bool {
        guard !isTerminated else { return false }
        switch AmbientRuntimeIdentity.processStatus(
            processIdentifier: processIdentifier,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: runningProcessStartDate
        ) {
        case .current:
            return true
        case .replaced:
            return false
        case .unknown:
            return true
        }
    }

    private static func sendQuitAppleEvent(
        processIdentifier: Int32
    ) -> Bool {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: NSAppleEventDescriptor(
                processIdentifier: processIdentifier
            ),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            _ = try event.sendEvent(
                options: [.noReply, .neverInteract],
                timeout: 1
            )
            return true
        } catch {
            return false
        }
    }

#endif

#if os(macOS)
    actor CodeValidator {
        private let check: @Sendable (URL, URL) -> Bool

        init(validate: @escaping @Sendable (URL, URL) -> Bool) {
            check = validate
        }

        func validate(helperURL: URL, extensionURL: URL) -> Bool {
            check(helperURL.standardizedFileURL, extensionURL.standardizedFileURL)
        }
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &code
        )
        guard status == errSecSuccess else {
            logger.error("Static code creation failed: \(status)")
            return nil
        }
        return code
    }

    private static func teamIdentifier(for code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
                  code,
                  SecCSFlags(rawValue: kSecCSSigningInformation),
                  &information
              ) == errSecSuccess,
              let values = information as? [CFString: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }
#endif
}
