import Foundation

public enum RuntimeTestResources {
    public static func wireProtocolFixture() throws -> Data { try fixture(named: "wire_protocol_contract") }
    public static func nativeResponseFixture() throws -> Data { try fixture(named: "native_response_contract") }

    private static func fixture(named name: String) throws -> Data {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
