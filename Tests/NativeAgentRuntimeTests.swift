import WalletFlows
#if os(macOS)
import Darwin
import Foundation
import Security
import XCTest
@testable import Big_Wallet

final class NativeAgentRuntimeTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("native-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    func testBuiltHelperAndExtensionPreserveTheirCodeSignatures() throws {
        let extensionURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
            .appendingPathComponent("Safari macOS.appex", isDirectory: true)
        let helperURL = try XCTUnwrap(NativeAgentRuntime.embeddedHelperURL(in: extensionURL))
        for (url, flags) in [
            (helperURL, kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
            (extensionURL, kSecCSStrictValidate),
        ] {
            var code: SecStaticCode?
            XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess, url.path)
            XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), SecCSFlags(rawValue: flags), nil),
                errSecSuccess, url.path)
        }
    }

    func testEmbeddedHelperStaysInsideTheSafariExtensionBundle() throws {
        let extensionURL = URL(fileURLWithPath:
            "/Users/developer/Build/Wallet.app/Contents/PlugIns/Safari macOS.appex",
            isDirectory: true
        )
        let helperURL = try XCTUnwrap(
            NativeAgentRuntime.embeddedHelperURL(in: extensionURL)
        )
        XCTAssertEqual(
            helperURL.path,
            extensionURL.path + "/Contents/Helpers/Big Wallet.app"
        )
        XCTAssertNil(NativeAgentRuntime.embeddedHelperURL(
            in: extensionURL.deletingLastPathComponent()
        ))
        XCTAssertNil(NativeAgentRuntime.embeddedHelperURL(
            in: URL(string: "https://example.com/Safari.appex")!
        ))
    }

    @MainActor
    func testNativeCodeValidationRechecksMappedResourcesOffMainActor() async throws {
        let helperURL = try makeAmbientBundle(name: "Mapped Helper", build: "149")
        let resourceURL = helperURL.appendingPathComponent("Contents/resource")
        try Data([1]).write(to: resourceURL)
        let descriptor = open(resourceURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let mapping = try XCTUnwrap(mmap(nil, 1, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0))
        guard mapping != MAP_FAILED else { return XCTFail("Failed to map resource") }
        defer { munmap(mapping, 1) }
        mapping.storeBytes(of: UInt8(1), as: UInt8.self)

        let checks = expectation(description: "Validate every request")
        checks.expectedFulfillmentCount = 4
        checks.assertForOverFulfill = true
        let validator = NativeAgentRuntime.CodeValidator(validate: { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            checks.fulfill()
            return (try? Data(contentsOf: resourceURL)) == Data([1])
        })
        let original = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        let repeated = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        XCTAssertTrue(original)
        XCTAssertTrue(repeated)
        mapping.storeBytes(of: UInt8(2), as: UInt8.self)
        let changed = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        XCTAssertFalse(changed)
        mapping.storeBytes(of: UInt8(1), as: UInt8.self)
        let restored = await validator.validate(helperURL: helperURL, extensionURL: helperURL)
        XCTAssertTrue(restored)
        await fulfillment(of: [checks], timeout: 1)
    }
    private func makeAmbientBundle(name: String, build: String) throws -> URL {
        let bundleURL = rootURL.appendingPathComponent(
            "\(name)-\(UUID().uuidString).app",
            isDirectory: true
        )
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.lil.wallet.ambient",
                "CFBundleShortVersionString": "1.0.99",
                "CFBundleVersion": build,
            ],
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
        return bundleURL.standardizedFileURL
    }


}
#endif
