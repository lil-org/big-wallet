import Foundation
import Security
import Synchronization
import XCTest
@testable import WalletNetworking

final class AlchemyJWTKeychainStoreTests: XCTestCase {
    private let persisted = AlchemyJWTPersistedState(revision: 7, record: nil, tombstones: [])

    func testLoadUsesOnlyTheRPCAuthenticationRecord() throws {
        let fixture = KeychainFixture(data: try JSONEncoder().encode(persisted))
        XCTAssertEqual(try fixture.store.load(), persisted)
        let query = try XCTUnwrap(fixture.queries.first)
        assertRPCScope(query)
        XCTAssertEqual(query.operation, .read)
        XCTAssertEqual(query.returnData, true)
        XCTAssertEqual(query.matchLimit, kSecMatchLimitOne as String)
        XCTAssertNil(query.accessible)
    }

    func testSavePreservesScopeThroughUpdateInsertionAndDuplicateRetry() throws {
        for (updates, add, operations) in [
            ([errSecSuccess], errSecSuccess, [Operation.update]),
            ([errSecItemNotFound], errSecSuccess, [.update, .add]),
            ([errSecItemNotFound, errSecSuccess], errSecDuplicateItem, [.update, .add, .update]),
        ] {
            let fixture = KeychainFixture(updateStatuses: updates, addStatus: add)
            try fixture.store.save(persisted)
            XCTAssertEqual(fixture.queries.map(\.operation), operations)
            for query in fixture.queries {
                assertRPCScope(query)
                let data = try XCTUnwrap(query.data)
                XCTAssertEqual(AlchemyJWTPersistedState.decodePersistenceData(data), persisted)
                XCTAssertEqual(query.accessible, query.operation == .add
                    ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String : nil)
            }
        }
    }

    func testMissingCorruptAndUnavailableReadsRemainDistinct() throws {
        XCTAssertNil(try KeychainFixture(readStatus: errSecItemNotFound).store.load())
        for (fixture, expected) in [
            (KeychainFixture(data: Data("invalid".utf8)), AlchemyJWTStorageError.invalidData),
            (KeychainFixture(readStatus: errSecInteractionNotAllowed), .transient),
        ] {
            XCTAssertThrowsError(try fixture.store.load()) { error in
                XCTAssertEqual(error as? AlchemyJWTStorageError, expected)
            }
            XCTAssertEqual(fixture.queries.count, 1)
            assertRPCScope(try XCTUnwrap(fixture.queries.first))
        }
    }

    func testUnavailableUpdateDoesNotInsertOrRetryElsewhere() {
        let fixture = KeychainFixture(updateStatuses: [errSecInteractionNotAllowed])
        XCTAssertThrowsError(try fixture.store.save(persisted)) { error in
            XCTAssertEqual(error as? AlchemyJWTStorageError, .transient)
        }
        XCTAssertEqual(fixture.queries.map(\.operation), [.update])
        fixture.queries.forEach { assertRPCScope($0) }
    }

    private func assertRPCScope(_ query: Query, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query.itemClass, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query.accessGroup, "8DXC3N7E7P.org.lil.wallet.rpc-auth", file: file, line: line)
        XCTAssertEqual(query.service, "org.lil.wallet.alchemy-jwt", file: file, line: line)
        XCTAssertEqual(query.account, "shared-token-v1", file: file, line: line)
        XCTAssertEqual(query.dataProtection, true, file: file, line: line)
    }

    private enum Operation: Sendable { case read, update, add }

    private struct Query: Sendable {
        let operation: Operation
        let itemClass: String?
        let accessGroup: String?
        let service: String?
        let account: String?
        let dataProtection: Bool?
        let accessible: String?
        let returnData: Bool?
        let matchLimit: String?
        let data: Data?

        init(_ operation: Operation, _ query: CFDictionary, attributes: CFDictionary? = nil) {
            let values = query as NSDictionary
            self.operation = operation
            itemClass = values[kSecClass] as? String
            accessGroup = values[kSecAttrAccessGroup] as? String
            service = values[kSecAttrService] as? String
            account = values[kSecAttrAccount] as? String
            dataProtection = values[kSecUseDataProtectionKeychain] as? Bool
            accessible = values[kSecAttrAccessible] as? String
            returnData = values[kSecReturnData] as? Bool
            matchLimit = values[kSecMatchLimit] as? String
            data = (attributes.map { $0 as NSDictionary } ?? values)[kSecValueData] as? Data
        }
    }

    private final class KeychainFixture: Sendable {
        private struct State {
            var queries = [Query]()
            var updateStatuses: [OSStatus]
        }
        private let state: Mutex<State>
        private let data: Data?
        private let readStatus: OSStatus
        private let addStatus: OSStatus

        init(data: Data? = nil, readStatus: OSStatus = errSecSuccess,
             updateStatuses: [OSStatus] = [], addStatus: OSStatus = errSecSuccess) {
            self.data = data
            self.readStatus = readStatus
            self.addStatus = addStatus
            state = Mutex(State(updateStatuses: updateStatuses))
        }

        var queries: [Query] { state.withLock { $0.queries } }
        var store: AlchemyJWTKeychainStore {
            AlchemyJWTKeychainStore(copyMatching: { query, item in
                self.state.withLock { $0.queries.append(Query(.read, query)) }
                if self.readStatus == errSecSuccess { item?.pointee = self.data as NSData? }
                return self.readStatus
            }, update: { query, attributes in
                self.state.withLock { state in
                    state.queries.append(Query(.update, query, attributes: attributes))
                    return state.updateStatuses.isEmpty ? errSecParam : state.updateStatuses.removeFirst()
                }
            }, add: { query, _ in
                self.state.withLock { $0.queries.append(Query(.add, query)) }
                return self.addStatus
            })
        }
    }
}
