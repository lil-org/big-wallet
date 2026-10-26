// ∅ 2026 lil org

import Foundation

public struct SolanaCompiledInstruction: Equatable, Sendable {
    public let programIdIndex: Int
    public let accountIndices: [Int]
    public let data: Data

    public init(programIdIndex: Int, accountIndices: [Int], data: Data) {
        self.programIdIndex = programIdIndex
        self.accountIndices = accountIndices
        self.data = data
    }
}

public struct SolanaAddressTableLookup: Equatable, Sendable {
    public let accountKey: Data
    public let writableIndexes: [Int]
    public let readOnlyIndexes: [Int]

    public init(accountKey: Data, writableIndexes: [Int], readOnlyIndexes: [Int]) {
        self.accountKey = accountKey
        self.writableIndexes = writableIndexes
        self.readOnlyIndexes = readOnlyIndexes
    }
}

public struct SolanaWireMessage: Sendable {
    public enum Version: Equatable, Sendable {
        case legacy
        case version0
    }

    public let version: Version
    public let requiredSignaturesCount: Int
    public let readOnlySignedAccountsCount: Int
    public let readOnlyUnsignedAccountsCount: Int
    public let accountKeys: [Data]
    public let blockhashRange: Range<Data.Index>
    public let instructions: [SolanaCompiledInstruction]
    public let addressTableLookups: [SolanaAddressTableLookup]

    public var feePayer: Data? {
        return accountKeys.first
    }

    public var loadedWritableAddressCount: Int {
        return addressTableLookups.reduce(0) { $0 + $1.writableIndexes.count }
    }

    public var loadedReadOnlyAddressCount: Int {
        return addressTableLookups.reduce(0) { $0 + $1.readOnlyIndexes.count }
    }

    public var totalReferencedAccountCount: Int {
        return accountKeys.count + loadedWritableAddressCount + loadedReadOnlyAddressCount
    }

    public func accountKey(at index: Int) -> Data? {
        guard index >= 0, index < accountKeys.count else { return nil }
        return accountKeys[index]
    }

    public func isSigner(accountIndex index: Int) -> Bool {
        return index >= 0 && index < requiredSignaturesCount
    }

    public func isWritable(accountIndex index: Int) -> Bool {
        guard index >= 0 else { return false }
        if index < accountKeys.count {
            if index < requiredSignaturesCount {
                return index < requiredSignaturesCount - readOnlySignedAccountsCount
            }

            return index < accountKeys.count - readOnlyUnsignedAccountsCount
        }

        let loadedIndex = index - accountKeys.count
        return loadedIndex < loadedWritableAddressCount
    }

    public init(version: Version, requiredSignaturesCount: Int, readOnlySignedAccountsCount: Int, readOnlyUnsignedAccountsCount: Int, accountKeys: [Data], blockhashRange: Range<Data.Index>, instructions: [SolanaCompiledInstruction], addressTableLookups: [SolanaAddressTableLookup]) {
        self.version = version
        self.requiredSignaturesCount = requiredSignaturesCount
        self.readOnlySignedAccountsCount = readOnlySignedAccountsCount
        self.readOnlyUnsignedAccountsCount = readOnlyUnsignedAccountsCount
        self.accountKeys = accountKeys
        self.blockhashRange = blockhashRange
        self.instructions = instructions
        self.addressTableLookups = addressTableLookups
    }
}

public struct SolanaPreparedTransactionMessage: Sendable {
    public let messageData: Data
    public let parsedMessage: SolanaWireMessage

    public init(messageData: Data, parsedMessage: SolanaWireMessage) {
        self.messageData = messageData
        self.parsedMessage = parsedMessage
    }
}

public enum SolanaWireMessageParser {
    private static let publicKeyLength = 32
    private static let blockhashLength = 32
    private static let maxMessageLength = Solana.maxWirePayloadLength
    private static let versionedMessageMask: UInt8 = 0x80
    private static let versionMask: UInt8 = 0x7f
    private static let supportedVersionedMessageVersion: UInt8 = 0
    private static let maxReferencedAccountCount = Int(UInt8.max) + 1

    private struct Prefix {
        let version: SolanaWireMessage.Version
        let requiredSignaturesCount: Int
        let readOnlySignedAccountsCount: Int
        let readOnlyUnsignedAccountsCount: Int
        let accountCountOffset: Int
        let isVersioned: Bool
    }

    private struct ParsedInstructions {
        let instructions: [SolanaCompiledInstruction]
        let highestAccountIndex: Int?
        let highestProgramIdIndex: Int?
    }

    public static func parse(_ messageData: Data) -> SolanaWireMessage? {
        guard messageData.count <= maxMessageLength else { return nil }

        guard let prefix = prefix(for: messageData),
              let accountCountIndex = messageData.index(messageData.startIndex, offsetBy: prefix.accountCountOffset, limitedBy: messageData.endIndex),
              let decodedLength = messageData.decodeLength(startingAt: accountCountIndex)
        else { return nil }

        guard decodedLength.length >= prefix.requiredSignaturesCount else { return nil }
        guard prefix.readOnlySignedAccountsCount < prefix.requiredSignaturesCount else { return nil }
        guard prefix.readOnlyUnsignedAccountsCount <= decodedLength.length - prefix.requiredSignaturesCount else { return nil }

        let (accountKeysLength, didOverflow) = decodedLength.length.multipliedReportingOverflow(by: publicKeyLength)
        guard !didOverflow,
              let accountKeysEndIndex = messageData.index(decodedLength.nextIndex, offsetBy: accountKeysLength, limitedBy: messageData.endIndex),
              let blockhashEndIndex = messageData.index(accountKeysEndIndex, offsetBy: blockhashLength, limitedBy: messageData.endIndex)
        else { return nil }

        var cursor = blockhashEndIndex
        guard let parsedInstructions = parseInstructions(in: messageData, cursor: &cursor) else { return nil }

        let addressTableLookups: [SolanaAddressTableLookup]
        if prefix.isVersioned {
            guard let parsedAddressTableLookups = parseAddressTableLookups(in: messageData, cursor: &cursor) else { return nil }
            addressTableLookups = parsedAddressTableLookups
        } else {
            addressTableLookups = []
        }

        guard cursor == messageData.endIndex else { return nil }

        let loadedAddressCount = addressTableLookups.reduce(0) { count, lookup in
            count + lookup.writableIndexes.count + lookup.readOnlyIndexes.count
        }
        let (totalAddressCount, addressCountOverflow) = decodedLength.length.addingReportingOverflow(loadedAddressCount)
        guard !addressCountOverflow else { return nil }
        guard totalAddressCount <= maxReferencedAccountCount else { return nil }
        if let highestProgramIdIndex = parsedInstructions.highestProgramIdIndex {
            guard highestProgramIdIndex < decodedLength.length else { return nil }
        }
        if let highestInstructionAccountIndex = parsedInstructions.highestAccountIndex {
            guard highestInstructionAccountIndex < totalAddressCount else { return nil }
        }

        var accountKeys = [Data]()
        accountKeys.reserveCapacity(decodedLength.length)

        var accountKeyStartIndex = decodedLength.nextIndex
        for _ in 0..<decodedLength.length {
            guard let accountKeyEndIndex = messageData.index(accountKeyStartIndex, offsetBy: publicKeyLength, limitedBy: accountKeysEndIndex)
            else {
                return nil
            }

            accountKeys.append(messageData.subdata(in: accountKeyStartIndex..<accountKeyEndIndex))
            accountKeyStartIndex = accountKeyEndIndex
        }

        guard accountKeyStartIndex == accountKeysEndIndex else { return nil }

        return SolanaWireMessage(version: prefix.version,
                                 requiredSignaturesCount: prefix.requiredSignaturesCount,
                                 readOnlySignedAccountsCount: prefix.readOnlySignedAccountsCount,
                                 readOnlyUnsignedAccountsCount: prefix.readOnlyUnsignedAccountsCount,
                                 accountKeys: accountKeys,
                                 blockhashRange: accountKeysEndIndex..<blockhashEndIndex,
                                 instructions: parsedInstructions.instructions,
                                 addressTableLookups: addressTableLookups)
    }

    private static func prefix(for messageData: Data) -> Prefix? {
        guard let firstByte = messageData.first else { return nil }
        if firstByte & versionedMessageMask == 0 {
            guard let readOnlySignedAccountsCount = byte(at: 1, in: messageData),
                  let readOnlyUnsignedAccountsCount = byte(at: 2, in: messageData)
            else { return nil }

            return Prefix(version: .legacy,
                          requiredSignaturesCount: Int(firstByte),
                          readOnlySignedAccountsCount: Int(readOnlySignedAccountsCount),
                          readOnlyUnsignedAccountsCount: Int(readOnlyUnsignedAccountsCount),
                          accountCountOffset: 3,
                          isVersioned: false)
        } else {
            guard firstByte & versionMask == supportedVersionedMessageVersion else { return nil }

            guard let requiredSignaturesCount = byte(at: 1, in: messageData),
                  let readOnlySignedAccountsCount = byte(at: 2, in: messageData),
                  let readOnlyUnsignedAccountsCount = byte(at: 3, in: messageData)
            else {
                return nil
            }
            return Prefix(version: .version0,
                          requiredSignaturesCount: Int(requiredSignaturesCount),
                          readOnlySignedAccountsCount: Int(readOnlySignedAccountsCount),
                          readOnlyUnsignedAccountsCount: Int(readOnlyUnsignedAccountsCount),
                          accountCountOffset: 4,
                          isVersioned: true)
        }
    }

    private static func parseInstructions(in messageData: Data, cursor: inout Data.Index) -> ParsedInstructions? {
        guard let instructionCount = readLength(in: messageData, cursor: &cursor) else { return nil }

        var highestAccountIndex: Int?
        var highestProgramIdIndex: Int?
        var instructions = [SolanaCompiledInstruction]()
        for _ in 0..<instructionCount {
            guard let programIdIndex = readByte(in: messageData, cursor: &cursor),
                  let accountIndexCount = readLength(in: messageData, cursor: &cursor),
                  let accountIndicesEndIndex = messageData.index(cursor, offsetBy: accountIndexCount, limitedBy: messageData.endIndex)
            else {
                return nil
            }

            guard programIdIndex != 0 else { return nil }

            updateHighestIndex(&highestProgramIdIndex, with: programIdIndex)
            var accountIndexCursor = cursor
            var accountIndices = [Int]()
            accountIndices.reserveCapacity(accountIndexCount)
            while accountIndexCursor < accountIndicesEndIndex {
                let accountIndex = messageData[accountIndexCursor]
                updateHighestIndex(&highestAccountIndex, with: accountIndex)
                accountIndices.append(Int(accountIndex))
                accountIndexCursor = messageData.index(after: accountIndexCursor)
            }
            cursor = accountIndicesEndIndex

            guard let instructionDataLength = readLength(in: messageData, cursor: &cursor),
                  let instructionDataEndIndex = messageData.index(cursor,
                                                                  offsetBy: instructionDataLength,
                                                                  limitedBy: messageData.endIndex)
            else {
                return nil
            }
            let instructionData = messageData.subdata(in: cursor..<instructionDataEndIndex)
            instructions.append(SolanaCompiledInstruction(programIdIndex: Int(programIdIndex),
                                                          accountIndices: accountIndices,
                                                          data: instructionData))
            cursor = instructionDataEndIndex
        }

        return ParsedInstructions(instructions: instructions,
                                  highestAccountIndex: highestAccountIndex,
                                  highestProgramIdIndex: highestProgramIdIndex)
    }

    private static func updateHighestIndex(_ highestIndex: inout Int?, with index: UInt8) {
        let index = Int(index)
        highestIndex = highestIndex.map { max($0, index) } ?? index
    }

    private static func parseAddressTableLookups(in messageData: Data, cursor: inout Data.Index) -> [SolanaAddressTableLookup]? {
        guard let lookupCount = readLength(in: messageData, cursor: &cursor) else { return nil }

        var loadedAddressCount = 0
        var lookups = [SolanaAddressTableLookup]()
        for _ in 0..<lookupCount {
            guard let accountKeyEndIndex = messageData.index(cursor, offsetBy: publicKeyLength, limitedBy: messageData.endIndex)
            else {
                return nil
            }
            let accountKey = messageData.subdata(in: cursor..<accountKeyEndIndex)
            cursor = accountKeyEndIndex

            guard let writableIndexCount = readLength(in: messageData, cursor: &cursor),
                  let writableIndexes = readIndexes(count: writableIndexCount, in: messageData, cursor: &cursor),
                  let readOnlyIndexCount = readLength(in: messageData, cursor: &cursor),
                  let readOnlyIndexes = readIndexes(count: readOnlyIndexCount, in: messageData, cursor: &cursor)
            else {
                return nil
            }

            let (lookupLoadedAddressCount, lookupOverflow) = writableIndexCount.addingReportingOverflow(readOnlyIndexCount)
            guard !lookupOverflow, lookupLoadedAddressCount > 0 else { return nil }
            let (combinedLoadedAddressCount, loadedAddressOverflow) = loadedAddressCount.addingReportingOverflow(lookupLoadedAddressCount)
            guard !loadedAddressOverflow else { return nil }
            loadedAddressCount = combinedLoadedAddressCount
            lookups.append(SolanaAddressTableLookup(accountKey: accountKey,
                                                    writableIndexes: writableIndexes,
                                                    readOnlyIndexes: readOnlyIndexes))
        }

        return lookups
    }

    private static func readIndexes(count: Int, in messageData: Data, cursor: inout Data.Index) -> [Int]? {
        guard count >= 0,
              let endIndex = messageData.index(cursor, offsetBy: count, limitedBy: messageData.endIndex)
        else {
            return nil
        }

        var indexes = [Int]()
        indexes.reserveCapacity(count)
        while cursor < endIndex {
            indexes.append(Int(messageData[cursor]))
            cursor = messageData.index(after: cursor)
        }
        return indexes
    }

    private static func readLength(in messageData: Data, cursor: inout Data.Index) -> Int? {
        guard let decodedLength = messageData.decodeLength(startingAt: cursor) else { return nil }
        cursor = decodedLength.nextIndex
        return decodedLength.length
    }

    private static func readByte(in messageData: Data, cursor: inout Data.Index) -> UInt8? {
        guard cursor < messageData.endIndex else { return nil }
        let byte = messageData[cursor]
        cursor = messageData.index(after: cursor)
        return byte
    }

    private static func byte(at offset: Int, in messageData: Data) -> UInt8? {
        guard let index = messageData.index(messageData.startIndex, offsetBy: offset, limitedBy: messageData.endIndex),
              index < messageData.endIndex
        else {
            return nil
        }

        return messageData[index]
    }
}

extension Data {

    public func decodeLength(startingAt startIndex: Data.Index) -> (length: Int, nextIndex: Data.Index)? {
        guard startIndex < endIndex else { return nil }

        var length: UInt = 0
        var shift = 0
        var index = startIndex

        while index < endIndex {
            let element = self[index]
            index = self.index(after: index)
            guard distance(from: startIndex, to: index) <= 3 else { return nil }

            guard shift < UInt.bitWidth else { return nil }
            let multiplier = UInt(1) << shift
            let (component, componentOverflow) = UInt(element & 0x7f).multipliedReportingOverflow(by: multiplier)
            guard !componentOverflow else { return nil }
            let (newLength, didOverflow) = length.addingReportingOverflow(component)
            guard !didOverflow else { return nil }
            length = newLength

            if element & 0x80 == 0 {
                guard length <= UInt(UInt16.max),
                      let intLength = Int(exactly: length),
                      subdata(in: startIndex..<index) == Self.encodeLength(intLength)
                else { return nil }
                return (length: intLength, nextIndex: index)
            }

            shift += 7
        }

        return nil
    }

    public static func encodeLength(_ length: Int) -> Data {
        return encodeLength(UInt(length))
    }

    private static func encodeLength(_ length: UInt) -> Data {
        var remainingLength = length
        var bytes = Data()

        while true {
            var element = remainingLength & 0x7f
            remainingLength = remainingLength >> 7
            if remainingLength == 0 {
                bytes.append(UInt8(element))
                break
            } else {
                element = element | 0x80
                bytes.append(UInt8(element))
            }
        }

        return bytes
    }

    public func solanaUInt32LE(at offset: Int) -> UInt32? {
        var value: UInt32 = 0
        for byteOffset in 0..<4 {
            guard let byte = byte(at: offset + byteOffset) else { return nil }
            value |= UInt32(byte) << (byteOffset * 8)
        }
        return value
    }

    public func solanaUInt64LE(at offset: Int) -> UInt64? {
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            guard let byte = byte(at: offset + byteOffset) else { return nil }
            value |= UInt64(byte) << (byteOffset * 8)
        }
        return value
    }

    private func byte(at offset: Int) -> UInt8? {
        guard offset >= 0,
              let start = index(startIndex, offsetBy: offset, limitedBy: endIndex),
              start < endIndex
        else {
            return nil
        }
        return self[start]
    }

}
