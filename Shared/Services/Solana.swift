// ∅ 2026 lil org

import Foundation
import WalletCore

struct SolanaCompiledInstruction: Equatable {
    let programIdIndex: Int
    let accountIndices: [Int]
    let data: Data
}

struct SolanaAddressTableLookup: Equatable {
    let accountKey: Data
    let writableIndexes: [Int]
    let readOnlyIndexes: [Int]
}

struct SolanaWireMessage {
    enum Version: Equatable {
        case legacy
        case version0
    }

    let version: Version
    let requiredSignaturesCount: Int
    let readOnlySignedAccountsCount: Int
    let readOnlyUnsignedAccountsCount: Int
    let accountKeys: [Data]
    let blockhashRange: Range<Data.Index>
    let instructions: [SolanaCompiledInstruction]
    let addressTableLookups: [SolanaAddressTableLookup]

    var feePayer: Data? {
        return accountKeys.first
    }

    var loadedWritableAddressCount: Int {
        return addressTableLookups.reduce(0) { $0 + $1.writableIndexes.count }
    }

    var loadedReadOnlyAddressCount: Int {
        return addressTableLookups.reduce(0) { $0 + $1.readOnlyIndexes.count }
    }

    var totalReferencedAccountCount: Int {
        return accountKeys.count + loadedWritableAddressCount + loadedReadOnlyAddressCount
    }

    func accountKey(at index: Int) -> Data? {
        guard index >= 0, index < accountKeys.count else { return nil }
        return accountKeys[index]
    }

    func isSigner(accountIndex index: Int) -> Bool {
        return index >= 0 && index < requiredSignaturesCount
    }

    func isWritable(accountIndex index: Int) -> Bool {
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
}

enum SolanaWireMessageParser {
    private static let publicKeyLength = 32
    private static let blockhashLength = 32
    private static let maxMessageLength = 1_232
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

    static func parse(_ messageData: Data) -> SolanaWireMessage? {
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

enum SolanaApprovalTextSanitizer {
    private static let unsafeFormatScalars = CharacterSet(charactersIn: "\u{061c}\u{200b}\u{200c}\u{200d}\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{feff}")

    static func inline(_ text: String, maxLength: Int = 500) -> String {
        guard maxLength > 0 else { return "" }

        var result = ""
        result.reserveCapacity(min(text.count, maxLength))

        func truncated(_ value: String) -> String {
            guard maxLength > 3 else { return String(repeating: ".", count: maxLength) }
            return String(value.prefix(maxLength - 3)) + "..."
        }

        func append(_ value: String) -> String? {
            guard result.count + value.count <= maxLength else {
                return truncated(result + value)
            }
            result += value
            return nil
        }

        for scalar in text.unicodeScalars {
            let replacement: String
            switch scalar {
            case "\n":
                replacement = "\\n"
            case "\r":
                replacement = "\\r"
            case "\t":
                replacement = "\\t"
            case _ where CharacterSet.newlines.contains(scalar):
                replacement = "\\n"
            case _ where unsafeFormatScalars.contains(scalar):
                continue
            case _ where CharacterSet.controlCharacters.contains(scalar):
                replacement = " "
            default:
                replacement = String(scalar)
            }

            if let truncated = append(replacement) {
                return truncated
            }
        }

        return result
    }
}

enum SolanaTransactionSummaryFormatter {
    private struct InstructionSummary {
        let title: String
        let details: [String]
        let riskNotes: [String]
        let isUnknown: Bool
    }

    private static let systemProgramID = Base58.decodeNoCheck(string: "11111111111111111111111111111111")!
    private static let tokenProgramID = Base58.decodeNoCheck(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!
    private static let token2022ProgramID = Base58.decodeNoCheck(string: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")!
    private static let associatedTokenProgramID = Base58.decodeNoCheck(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!
    private static let computeBudgetProgramID = Base58.decodeNoCheck(string: "ComputeBudget111111111111111111111111111111")!
    private static let memoProgramID = Base58.decodeNoCheck(string: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")!
    private static let legacyMemoProgramID = Base58.decodeNoCheck(string: "Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo")!

    static func approvalMessage(messageData: Data, encodedMessages: [String]) -> String {
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData) else {
            return rawApprovalMessage(messages: encodedMessages)
        }

        return approvalMessage(parsedMessage: parsedMessage,
                               messageData: messageData,
                               encodedMessages: encodedMessages)
    }

    static func approvalMessage(encodedMessages: [String], messageDataList: [Data]) -> String {
        guard encodedMessages.count == messageDataList.count else {
            return rawApprovalMessage(messages: encodedMessages)
        }
        guard !encodedMessages.isEmpty else {
            return rawApprovalMessage(messages: encodedMessages)
        }
        guard encodedMessages.count != 1 else {
            return approvalMessage(messageData: messageDataList[0],
                                   encodedMessages: [encodedMessages[0]])
        }

        return zip(encodedMessages, messageDataList).enumerated().map { index, values in
            let (encodedMessage, messageData) = values
            return "Transaction \(index + 1)\n\n" +
                approvalMessage(messageData: messageData,
                                encodedMessages: [encodedMessage])
        }.joined(separator: "\n\n")
    }

    static func approvalMessage(parsedMessage: SolanaWireMessage,
                                messageData: Data,
                                encodedMessages: [String]) -> String {
        let summaries = parsedMessage.instructions.map { instruction in
            instructionSummary(instruction: instruction, message: parsedMessage)
        }

        var sections = [summarySection(message: parsedMessage, messageData: messageData)]
        sections.append(actionsSection(summaries: summaries))
        let riskNotes = riskNotes(message: parsedMessage, summaries: summaries)
        if !riskNotes.isEmpty {
            sections.append((["Risk notes"] + riskNotes.map { "- \($0)" }).joined(separator: "\n"))
        }
        sections.append(rawDataSection(messages: encodedMessages))
        return sections.joined(separator: "\n\n")
    }

    static func rawApprovalMessage(messages: [String]) -> String {
        return Strings.rawSolanaTransactionWarning + "\n\n" + rawDataSection(messages: messages)
    }

    private static func summarySection(message: SolanaWireMessage, messageData: Data) -> String {
        var lines = ["Solana transaction"]
        lines.append("Version: \(message.version == .legacy ? "Legacy" : "v0")")
        if let feePayer = message.feePayer {
            lines.append("Fee payer: \(address(feePayer))")
        }
        lines.append("Recent blockhash: \(Base58.encodeNoCheck(data: messageData.subdata(in: message.blockhashRange)))")
        lines.append("Required signers: \(message.requiredSignaturesCount)")
        lines.append("Writable accounts: \(writableAccountCount(message))")
        lines.append("Instructions: \(message.instructions.count)")
        if message.addressTableLookups.isEmpty {
            lines.append("Address lookup tables: none")
        } else {
            lines.append("Address lookup tables: \(message.addressTableLookups.count) (\(message.loadedWritableAddressCount) writable, \(message.loadedReadOnlyAddressCount) read-only loaded addresses unresolved)")
        }
        return lines.joined(separator: "\n")
    }

    private static func actionsSection(summaries: [InstructionSummary]) -> String {
        var lines = ["Actions"]
        if summaries.isEmpty {
            lines.append("No instructions")
            return lines.joined(separator: "\n")
        }

        for (index, summary) in summaries.enumerated() {
            lines.append("\(index + 1). \(summary.title)")
            lines.append(contentsOf: summary.details.map { "   \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func riskNotes(message: SolanaWireMessage, summaries: [InstructionSummary]) -> [String] {
        var notes = [String]()
        let unknownCount = summaries.filter(\.isUnknown).count
        if unknownCount > 0 {
            notes.append("\(unknownCount) instruction\(unknownCount == 1 ? "" : "s") could not be decoded.")
        }
        if !message.addressTableLookups.isEmpty {
            notes.append("This v0 transaction uses address lookup tables; loaded addresses are not shown unless they also appear as static accounts.")
        }
        let writableSigners = message.accountKeys.indices.filter { $0 != 0 && message.isSigner(accountIndex: $0) && message.isWritable(accountIndex: $0) }
        for signerIndex in writableSigners {
            notes.append("Writable signer: \(address(message.accountKeys[signerIndex]))")
        }
        var seenNotes = Set(notes)
        for note in summaries.flatMap(\.riskNotes) where seenNotes.insert(note).inserted {
            notes.append(note)
        }
        return notes
    }

    private static func tokenRiskNotes(isToken2022: Bool,
                                       rawAmount: Bool = false,
                                       extra: [String] = []) -> [String] {
        var notes = extra
        if rawAmount {
            notes.append("Token amount is raw base units because this instruction does not include decimals.")
        }
        if isToken2022 {
            notes.append("Token-2022 accounts or mints may use extensions that are not fully reflected in this summary.")
        }
        return notes
    }

    private static func writableAccountCount(_ message: SolanaWireMessage) -> Int {
        return (0..<message.totalReferencedAccountCount).filter { message.isWritable(accountIndex: $0) }.count
    }

    private static func instructionSummary(instruction: SolanaCompiledInstruction,
                                           message: SolanaWireMessage) -> InstructionSummary {
        guard let programID = message.accountKey(at: instruction.programIdIndex) else {
            return unknownInstructionSummary(programID: nil, instruction: instruction, message: message)
        }

        if programID == systemProgramID {
            return systemInstructionSummary(instruction: instruction, message: message)
        }
        if programID == tokenProgramID || programID == token2022ProgramID {
            return tokenInstructionSummary(instruction: instruction, message: message, isToken2022: programID == token2022ProgramID)
        }
        if programID == associatedTokenProgramID {
            return associatedTokenInstructionSummary(instruction: instruction, message: message)
        }
        if programID == computeBudgetProgramID {
            return computeBudgetInstructionSummary(instruction: instruction)
        }
        if programID == memoProgramID || programID == legacyMemoProgramID {
            return memoInstructionSummary(instruction: instruction)
        }

        return unknownInstructionSummary(programID: programID, instruction: instruction, message: message)
    }

    private static func systemInstructionSummary(instruction: SolanaCompiledInstruction,
                                                 message: SolanaWireMessage) -> InstructionSummary {
        guard let discriminator = instruction.data.solanaUInt32LE(at: 0) else {
            return unknownInstructionSummary(programID: systemProgramID, instruction: instruction, message: message)
        }

        switch discriminator {
        case 0 where instruction.data.count == 52:
            let lamports = instruction.data.solanaUInt64LE(at: 4) ?? 0
            let space = instruction.data.solanaUInt64LE(at: 12) ?? 0
            let owner = instruction.data.subdata(in: 20..<52)
            return InstructionSummary(title: "Create SOL account",
                                      details: [
                                        "Funding account: \(accountDescription(at: 0, in: instruction, message: message))",
                                        "New account: \(accountDescription(at: 1, in: instruction, message: message))",
                                        "Lamports: \(lamports) (\(solAmount(lamports)) SOL)",
                                        "Space: \(space) bytes",
                                        "Owner program: \(address(owner))",
                                      ],
                                      riskNotes: [],
                                      isUnknown: false)
        case 1 where instruction.data.count == 36:
            let owner = instruction.data.subdata(in: 4..<36)
            return InstructionSummary(title: "Assign SOL account owner",
                                      details: [
                                        "Account: \(accountDescription(at: 0, in: instruction, message: message))",
                                        "New owner program: \(address(owner))",
                                      ],
                                      riskNotes: [],
                                      isUnknown: false)
        case 2 where instruction.data.count == 12:
            let lamports = instruction.data.solanaUInt64LE(at: 4) ?? 0
            return InstructionSummary(title: "Transfer \(solAmount(lamports)) SOL",
                                      details: [
                                        "From: \(accountDescription(at: 0, in: instruction, message: message))",
                                        "To: \(accountDescription(at: 1, in: instruction, message: message))",
                                        "Lamports: \(lamports)",
                                      ],
                                      riskNotes: [],
                                      isUnknown: false)
        default:
            return unknownInstructionSummary(programID: systemProgramID, instruction: instruction, message: message)
        }
    }

    private static func tokenInstructionSummary(instruction: SolanaCompiledInstruction,
                                                message: SolanaWireMessage,
                                                isToken2022: Bool) -> InstructionSummary {
        guard let discriminator = instruction.data.first else {
            return unknownInstructionSummary(programID: isToken2022 ? token2022ProgramID : tokenProgramID, instruction: instruction, message: message)
        }

        let programName = isToken2022 ? "Token-2022" : "SPL Token"
        switch discriminator {
        case 3 where instruction.data.count == 9:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            return InstructionSummary(title: "\(programName) transfer raw amount \(amount)",
                                      details: tokenTransferDetails(instruction: instruction, message: message, includeMint: false),
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022, rawAmount: true),
                                      isUnknown: false)
        case 12 where instruction.data.count == 10:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            let decimals = Int(instruction.data[9])
            return InstructionSummary(title: "\(programName) transfer \(decimalAmount(amount, decimals: decimals))",
                                      details: tokenTransferDetails(instruction: instruction, message: message, includeMint: true) + ["Decimals: \(decimals)"],
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022),
                                      isUnknown: false)
        case 4 where instruction.data.count == 9:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            return InstructionSummary(title: "\(programName) approve delegate raw amount \(amount)",
                                      details: tokenApprovalDetails(instruction: instruction, message: message, includeMint: false),
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022,
                                                                rawAmount: true,
                                                                extra: ["Token delegate approval lets another account spend from the source token account."]),
                                      isUnknown: false)
        case 13 where instruction.data.count == 10:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            let decimals = Int(instruction.data[9])
            return InstructionSummary(title: "\(programName) approve delegate \(decimalAmount(amount, decimals: decimals))",
                                      details: tokenApprovalDetails(instruction: instruction, message: message, includeMint: true) + ["Decimals: \(decimals)"],
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022,
                                                                extra: ["Token delegate approval lets another account spend from the source token account."]),
                                      isUnknown: false)
        case 5 where instruction.data.count == 1:
            return InstructionSummary(title: "\(programName) revoke delegate",
                                      details: [
                                        "Source token account: \(accountDescription(at: 0, in: instruction, message: message))",
                                        "Owner: \(accountDescription(at: 1, in: instruction, message: message))",
                                      ] + additionalSignerDetails(instruction: instruction, message: message, startingAt: 2),
                                      riskNotes: [],
                                      isUnknown: false)
        case 7 where instruction.data.count == 9:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            return InstructionSummary(title: "\(programName) mint raw amount \(amount)",
                                      details: mintOrBurnDetails(instruction: instruction, message: message, mintFirst: true),
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022, rawAmount: true),
                                      isUnknown: false)
        case 14 where instruction.data.count == 10:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            let decimals = Int(instruction.data[9])
            return InstructionSummary(title: "\(programName) mint \(decimalAmount(amount, decimals: decimals))",
                                      details: mintOrBurnDetails(instruction: instruction, message: message, mintFirst: true) + ["Decimals: \(decimals)"],
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022),
                                      isUnknown: false)
        case 8 where instruction.data.count == 9:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            return InstructionSummary(title: "\(programName) burn raw amount \(amount)",
                                      details: mintOrBurnDetails(instruction: instruction, message: message, mintFirst: false),
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022, rawAmount: true),
                                      isUnknown: false)
        case 15 where instruction.data.count == 10:
            let amount = instruction.data.solanaUInt64LE(at: 1) ?? 0
            let decimals = Int(instruction.data[9])
            return InstructionSummary(title: "\(programName) burn \(decimalAmount(amount, decimals: decimals))",
                                      details: mintOrBurnDetails(instruction: instruction, message: message, mintFirst: false) + ["Decimals: \(decimals)"],
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022),
                                      isUnknown: false)
        case 9 where instruction.data.count == 1:
            return InstructionSummary(title: "\(programName) close token account",
                                      details: [
                                        "Account: \(accountDescription(at: 0, in: instruction, message: message))",
                                        "Destination: \(accountDescription(at: 1, in: instruction, message: message))",
                                        "Owner: \(accountDescription(at: 2, in: instruction, message: message))",
                                      ] + additionalSignerDetails(instruction: instruction, message: message, startingAt: 3),
                                      riskNotes: tokenRiskNotes(isToken2022: isToken2022,
                                                                extra: ["Closing a token account moves its rent balance to the destination account."]),
                                      isUnknown: false)
        default:
            return unknownInstructionSummary(programID: isToken2022 ? token2022ProgramID : tokenProgramID, instruction: instruction, message: message)
        }
    }

    private static func associatedTokenInstructionSummary(instruction: SolanaCompiledInstruction,
                                                          message: SolanaWireMessage) -> InstructionSummary {
        if instruction.data.isEmpty || instruction.data == Data([0]) {
            return InstructionSummary(title: "Create associated token account",
                                      details: associatedTokenCreateDetails(instruction: instruction, message: message),
                                      riskNotes: [],
                                      isUnknown: false)
        } else if instruction.data.count == 1, instruction.data[0] == 1 {
            return InstructionSummary(title: "Create associated token account if needed",
                                      details: associatedTokenCreateDetails(instruction: instruction, message: message),
                                      riskNotes: [],
                                      isUnknown: false)
        } else if instruction.data.count == 1, instruction.data[0] == 2 {
            return InstructionSummary(title: "Recover nested associated token account",
                                      details: associatedTokenRecoverNestedDetails(instruction: instruction, message: message),
                                      riskNotes: ["Recovering a nested associated token account moves its tokens to the owner's associated token account."],
                                      isUnknown: false)
        }

        return unknownInstructionSummary(programID: associatedTokenProgramID, instruction: instruction, message: message)
    }

    private static func associatedTokenCreateDetails(instruction: SolanaCompiledInstruction,
                                                     message: SolanaWireMessage) -> [String] {
        return [
            "Payer: \(accountDescription(at: 0, in: instruction, message: message))",
            "Associated token account: \(accountDescription(at: 1, in: instruction, message: message))",
            "Owner: \(accountDescription(at: 2, in: instruction, message: message))",
            "Mint: \(accountDescription(at: 3, in: instruction, message: message))",
        ]
    }

    private static func associatedTokenRecoverNestedDetails(instruction: SolanaCompiledInstruction,
                                                           message: SolanaWireMessage) -> [String] {
        return [
            "Nested associated token account: \(accountDescription(at: 0, in: instruction, message: message))",
            "Nested token mint: \(accountDescription(at: 1, in: instruction, message: message))",
            "Destination associated token account: \(accountDescription(at: 2, in: instruction, message: message))",
            "Owner associated token account: \(accountDescription(at: 3, in: instruction, message: message))",
            "Owner token mint: \(accountDescription(at: 4, in: instruction, message: message))",
            "Wallet: \(accountDescription(at: 5, in: instruction, message: message))",
            "Token program: \(accountDescription(at: 6, in: instruction, message: message))",
        ]
    }

    private static func computeBudgetInstructionSummary(instruction: SolanaCompiledInstruction) -> InstructionSummary {
        guard let discriminator = instruction.data.first else {
            return InstructionSummary(title: "Compute Budget instruction",
                                      details: ["Data: empty"],
                                      riskNotes: [],
                                      isUnknown: true)
        }

        switch discriminator {
        case 1 where instruction.data.count == 5:
            return InstructionSummary(title: "Set transaction heap frame",
                                      details: ["Bytes: \(instruction.data.solanaUInt32LE(at: 1) ?? 0)"],
                                      riskNotes: [],
                                      isUnknown: false)
        case 2 where instruction.data.count == 5:
            return InstructionSummary(title: "Set compute unit limit",
                                      details: ["Units: \(instruction.data.solanaUInt32LE(at: 1) ?? 0)"],
                                      riskNotes: [],
                                      isUnknown: false)
        case 3 where instruction.data.count == 9:
            return InstructionSummary(title: "Set compute unit price",
                                      details: ["Micro-lamports per unit: \(instruction.data.solanaUInt64LE(at: 1) ?? 0)"],
                                      riskNotes: [],
                                      isUnknown: false)
        default:
            return InstructionSummary(title: "Compute Budget instruction",
                                      details: ["Data: \(shortHex(instruction.data))"],
                                      riskNotes: [],
                                      isUnknown: true)
        }
    }

    private static func memoInstructionSummary(instruction: SolanaCompiledInstruction) -> InstructionSummary {
        let memo = String(data: instruction.data, encoding: .utf8)
        let displayedMemo: String
        if let memo, !memo.isEmpty {
            displayedMemo = SolanaApprovalTextSanitizer.inline(memo)
        } else {
            displayedMemo = shortHex(instruction.data)
        }
        return InstructionSummary(title: "Memo",
                                  details: ["Text: \(displayedMemo)"],
                                  riskNotes: [],
                                  isUnknown: false)
    }

    private static func unknownInstructionSummary(programID: Data?,
                                                  instruction: SolanaCompiledInstruction,
                                                  message: SolanaWireMessage) -> InstructionSummary {
        var details = [String]()
        if let programID {
            details.append("Program: \(address(programID))")
        } else {
            details.append("Program index: \(instruction.programIdIndex)")
        }
        details.append("Accounts: \(instruction.accountIndices.map { accountDescription(index: $0, message: message) }.joined(separator: ", "))")
        details.append("Data length: \(instruction.data.count) bytes")
        details.append("Data prefix: \(shortHex(instruction.data))")
        return InstructionSummary(title: "Unknown program instruction",
                                  details: details,
                                  riskNotes: [],
                                  isUnknown: true)
    }

    private static func tokenTransferDetails(instruction: SolanaCompiledInstruction,
                                             message: SolanaWireMessage,
                                             includeMint: Bool) -> [String] {
        var details = [
            "Source token account: \(accountDescription(at: 0, in: instruction, message: message))",
        ]
        if includeMint {
            details.append("Mint: \(accountDescription(at: 1, in: instruction, message: message))")
            details.append("Destination token account: \(accountDescription(at: 2, in: instruction, message: message))")
            details.append("Authority: \(accountDescription(at: 3, in: instruction, message: message))")
            details.append(contentsOf: additionalSignerDetails(instruction: instruction, message: message, startingAt: 4))
        } else {
            details.append("Destination token account: \(accountDescription(at: 1, in: instruction, message: message))")
            details.append("Authority: \(accountDescription(at: 2, in: instruction, message: message))")
            details.append(contentsOf: additionalSignerDetails(instruction: instruction, message: message, startingAt: 3))
        }
        return details
    }

    private static func tokenApprovalDetails(instruction: SolanaCompiledInstruction,
                                             message: SolanaWireMessage,
                                             includeMint: Bool) -> [String] {
        var details = [
            "Source token account: \(accountDescription(at: 0, in: instruction, message: message))",
        ]
        if includeMint {
            details.append("Mint: \(accountDescription(at: 1, in: instruction, message: message))")
            details.append("Delegate: \(accountDescription(at: 2, in: instruction, message: message))")
            details.append("Owner: \(accountDescription(at: 3, in: instruction, message: message))")
            details.append(contentsOf: additionalSignerDetails(instruction: instruction, message: message, startingAt: 4))
        } else {
            details.append("Delegate: \(accountDescription(at: 1, in: instruction, message: message))")
            details.append("Owner: \(accountDescription(at: 2, in: instruction, message: message))")
            details.append(contentsOf: additionalSignerDetails(instruction: instruction, message: message, startingAt: 3))
        }
        return details
    }

    private static func mintOrBurnDetails(instruction: SolanaCompiledInstruction,
                                          message: SolanaWireMessage,
                                          mintFirst: Bool) -> [String] {
        if mintFirst {
            return [
                "Mint: \(accountDescription(at: 0, in: instruction, message: message))",
                "Token account: \(accountDescription(at: 1, in: instruction, message: message))",
                "Authority: \(accountDescription(at: 2, in: instruction, message: message))",
            ] + additionalSignerDetails(instruction: instruction, message: message, startingAt: 3)
        } else {
            return [
                "Token account: \(accountDescription(at: 0, in: instruction, message: message))",
                "Mint: \(accountDescription(at: 1, in: instruction, message: message))",
                "Authority: \(accountDescription(at: 2, in: instruction, message: message))",
            ] + additionalSignerDetails(instruction: instruction, message: message, startingAt: 3)
        }
    }

    private static func additionalSignerDetails(instruction: SolanaCompiledInstruction,
                                                message: SolanaWireMessage,
                                                startingAt firstSignerOffset: Int) -> [String] {
        guard firstSignerOffset < instruction.accountIndices.count else { return [] }
        return (firstSignerOffset..<instruction.accountIndices.count).map { signerOffset in
            let accountIndex = instruction.accountIndices[signerOffset]
            let label = message.isSigner(accountIndex: accountIndex) ? "Additional signer" : "Additional account"
            return "\(label) \(signerOffset - firstSignerOffset + 1): \(accountDescription(at: signerOffset, in: instruction, message: message))"
        }
    }

    private static func accountDescription(at instructionAccountOffset: Int,
                                           in instruction: SolanaCompiledInstruction,
                                           message: SolanaWireMessage) -> String {
        guard instructionAccountOffset < instruction.accountIndices.count else { return "missing account" }
        return accountDescription(index: instruction.accountIndices[instructionAccountOffset], message: message)
    }

    private static func accountDescription(index: Int, message: SolanaWireMessage) -> String {
        var components: [String]
        if let accountKey = message.accountKey(at: index) {
            components = [address(accountKey)]
        } else {
            components = ["loaded account #\(index - message.accountKeys.count + 1) (unresolved)"]
        }

        if message.isSigner(accountIndex: index) {
            components.append("signer")
        }
        if message.isWritable(accountIndex: index) {
            components.append("writable")
        }
        return components.joined(separator: " - ")
    }

    private static func address(_ data: Data) -> String {
        return Base58.encodeNoCheck(data: data)
    }

    private static func shortHex(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        let prefix = data.prefix(8)
        let suffix = data.count > prefix.count ? "..." : ""
        return "0x" + prefix.hexString + suffix
    }

    private static func solAmount(_ lamports: UInt64) -> String {
        return decimalAmount(lamports, decimals: 9)
    }

    private static func decimalAmount(_ amount: UInt64, decimals: Int) -> String {
        guard decimals > 0 else { return String(amount) }
        let raw = String(amount)
        if raw.count <= decimals {
            let padding = String(repeating: "0", count: decimals - raw.count)
            return "0." + (padding + raw).trimmingTrailingZeros(keepingAtLeastOneDecimal: true)
        }

        let splitIndex = raw.index(raw.endIndex, offsetBy: -decimals)
        let whole = raw[..<splitIndex]
        let fractional = String(raw[splitIndex...]).trimmingTrailingZeros(keepingAtLeastOneDecimal: false)
        return fractional.isEmpty ? String(whole) : "\(whole).\(fractional)"
    }

    private static func rawDataSection(messages: [String]) -> String {
        return Strings.data + ":\n\n" + messages.joined(separator: "\n\n")
    }
}

final class Solana {

    enum Cluster: String, CaseIterable {
        case mainnetBeta
        case devnet
        case testnet

        var displayName: String {
            switch self {
            case .mainnetBeta:
                return "Mainnet"
            case .devnet:
                return "Devnet"
            case .testnet:
                return "Testnet"
            }
        }

        fileprivate var rpcConfigurationKey: String {
            switch self {
            case .mainnetBeta:
                return "SolanaMainnetRPCURL"
            case .devnet:
                return "SolanaDevnetRPCURL"
            case .testnet:
                return "SolanaTestnetRPCURL"
            }
        }

        fileprivate var publicRPCFallbackURLString: String {
            switch self {
            case .mainnetBeta:
                return "https://api.mainnet.solana.com"
            case .devnet:
                return "https://api.devnet.solana.com"
            case .testnet:
                return "https://api.testnet.solana.com"
            }
        }

        init?(clusterHint: String) {
            switch clusterHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "mainnet", "mainnet-beta", "mainnetbeta", "solana:mainnet":
                self = .mainnetBeta
            case "devnet", "solana:devnet":
                self = .devnet
            case "testnet", "solana:testnet":
                self = .testnet
            default:
                return nil
            }
        }
    }

    enum SendTransactionError: Error, Equatable {
        case invalidMessage
        case unsupportedMultiSignature
        case blockhashNotFound
        case invalidSendOptions
        case confirmationFailed(signature: String, message: String, code: Int?)
        case confirmationTimedOut(signature: String)
        case rpcError(message: String, code: Int?)
        case unknown
    }

    enum Commitment: String, Decodable {
        case processed
        case confirmed
        case finalized

        func satisfies(_ requestedCommitment: Commitment) -> Bool {
            return confirmationRank >= requestedCommitment.confirmationRank
        }

        private var confirmationRank: Int {
            switch self {
            case .processed:
                return 0
            case .confirmed:
                return 1
            case .finalized:
                return 2
            }
        }
    }

    private enum Method: String {
        case getSignatureStatuses
        case sendTransaction
    }

    private struct SendTransactionResponse: Decodable {
        let result: String?
        private let error: RPCResponseError?

        var failure: SendTransactionError? {
            guard let error else { return nil }
            if error.isBlockhashNotFound {
                return .blockhashNotFound
            }

            return error.sendTransactionFailure
        }
    }

    private struct SignatureStatusesResponse: Decodable {
        private let result: ResultValue?
        private let error: RPCResponseError?

        var status: SignatureStatus? {
            guard let values = result?.value, !values.isEmpty else { return nil }
            return values[0]
        }

        var failure: SendTransactionError? {
            guard let error else { return nil }
            return error.sendTransactionFailure
        }

        struct ResultValue: Decodable {
            let value: [SignatureStatus?]
        }
    }

    private struct SignatureStatus: Decodable {
        let err: RPCErrorValue?
        let confirmations: Int?
        let confirmationStatus: Commitment?
        private let didReturnConfirmations: Bool

        private enum CodingKeys: String, CodingKey {
            case err, confirmations, confirmationStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            err = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .err)
            if container.contains(.confirmations) {
                if (try? container.decodeNil(forKey: .confirmations)) == true {
                    didReturnConfirmations = true
                    confirmations = nil
                } else if let decodedConfirmations = try? container.decode(Int.self, forKey: .confirmations),
                          decodedConfirmations >= 0 {
                    didReturnConfirmations = true
                    confirmations = decodedConfirmations
                } else {
                    didReturnConfirmations = false
                    confirmations = nil
                }
            } else {
                didReturnConfirmations = false
                confirmations = nil
            }
            confirmationStatus = try? container.decodeIfPresent(Commitment.self, forKey: .confirmationStatus)
        }

        var failure: SendTransactionError? {
            guard let err else { return nil }
            return .rpcError(message: err.displayMessage ?? Strings.failedToSend,
                             code: nil)
        }

        func satisfies(_ commitment: Commitment) -> Bool {
            if let confirmationStatus {
                return confirmationStatus.satisfies(commitment)
            }

            // Older RPC nodes may omit `confirmationStatus`; a present status
            // still proves the transaction reached at least processed. Fall
            // back to legacy `confirmations` for stronger commitments.
            switch commitment {
            case .processed:
                return err == nil
            case .confirmed:
                guard didReturnConfirmations else { return false }
                return confirmations == nil || (confirmations ?? 0) > 0
            case .finalized:
                return didReturnConfirmations && confirmations == nil
            }
        }
    }

    private struct RPCResponseError: Decodable {
        let code: Int?
        let message: String?
        let data: ResponseData?
        private let rawData: RPCErrorValue?

        private enum CodingKeys: String, CodingKey {
            case code, message, data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            data = try? container.decodeIfPresent(ResponseData.self, forKey: .data)
            rawData = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .data)
        }

        var displayMessage: String? {
            if let message, !message.isEmpty {
                return message
            }
            if let dataMessage = data?.message, !dataMessage.isEmpty {
                return dataMessage
            }
            return rawData?.displayMessage
        }

        var sendTransactionFailure: SendTransactionError {
            return .rpcError(message: displayMessage ?? Strings.failedToSend,
                             code: code)
        }

        var isBlockhashNotFound: Bool {
            return contains("BlockhashNotFound") ||
                contains("blockhash not found")
        }

        func contains(_ string: String) -> Bool {
            return message?.containsIgnoringCase(string) == true ||
                data?.contains(string) == true ||
                rawData?.contains(string) == true
        }

        struct ResponseData: Decodable {
            let err: RPCErrorValue?
            let message: String?

            private enum CodingKeys: String, CodingKey {
                case err, message
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                err = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .err)
                message = try? container.decodeIfPresent(String.self, forKey: .message)
            }

            func contains(_ string: String) -> Bool {
                return message?.containsIgnoringCase(string) == true ||
                    err?.contains(string) == true
            }
        }
    }

    private indirect enum RPCErrorValue: Decodable {
        case string(String)
        case array([RPCErrorValue])
        case object([String: RPCErrorValue])
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([RPCErrorValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: RPCErrorValue].self) {
                self = .object(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .null
            }
        }

        var displayMessage: String? {
            switch self {
            case .string(let value):
                return value.isEmpty ? nil : value
            case .array(let values):
                let messages = values.compactMap { $0.displayMessage }
                return messages.isEmpty ? nil : messages.joined(separator: ", ")
            case .object(let values):
                return values["message"]?.displayMessage ??
                    values["err"]?.displayMessage
            case .number, .bool, .null:
                return nil
            }
        }

        func contains(_ string: String) -> Bool {
            switch self {
            case .string(let value):
                return value.containsIgnoringCase(string)
            case .array(let values):
                return values.contains { $0.contains(string) }
            case .object(let values):
                return values.contains { key, value in
                    key.containsIgnoringCase(string) ||
                        value.contains(string)
                }
            case .number, .bool, .null:
                return false
            }
        }
    }

    fileprivate struct ParsedTransaction {
        let transactionData: Data
        let messageData: Data
        let messageRange: Range<Data.Index>
        let parsedMessage: SolanaWireMessage
        let signaturesStartIndex: Data.Index
    }

    fileprivate struct PreparedSignAndSendTransaction {
        let parsedTransaction: ParsedTransaction
        let signerSignatureRange: Range<Data.Index>
    }

    struct PreparedLegacySignAndSendTransaction {
        let approvalMessage: String
        let messageData: Data
        let parsedMessage: SolanaWireMessage
    }

    struct PreparedSerializedTransaction {
        let approvalMessage: String
        fileprivate let preparedTransaction: PreparedSignAndSendTransaction

        var messageData: Data {
            return preparedTransaction.parsedTransaction.messageData
        }
    }

    struct PreparedSendOptions {
        let clusterHint: Cluster?
        let rpcOptions: [String: Any]
        let confirmationCommitment: Commitment?
    }

    struct RPCEndpoint {
        let url: URL
        let source: RPCSource
    }

    enum RPCSource: Equatable {
        case configured
        case publicFallback

        var displayName: String {
            switch self {
            case .configured:
                return Strings.configuredRPC
            case .publicFallback:
                return Strings.publicRPC
            }
        }
    }

    struct RPCConfiguration {
        private let infoDictionary: [String: Any]

        init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
            self.infoDictionary = infoDictionary
        }

        func endpoint(for cluster: Cluster) -> RPCEndpoint {
            if let configuredURL = configuredURL(for: cluster) {
                return RPCEndpoint(url: configuredURL, source: .configured)
            }

            return RPCEndpoint(url: URL(string: cluster.publicRPCFallbackURLString)!,
                               source: .publicFallback)
        }

        private func configuredURL(for cluster: Cluster) -> URL? {
            guard let rawValue = infoDictionary[cluster.rpcConfigurationKey] as? String else {
                return nil
            }

            let urlString = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme)
            else {
                return nil
            }

            return url
        }
    }

    static let shared = Solana()

    private let urlSession = URLSession(configuration: .default)
    private let signatureLength = 64
    private let publicKeyLength = 32
    private let signatureStatusInitialPollInterval: TimeInterval = 0.5
    private let signatureStatusMaxPollInterval: TimeInterval = 2
    private let signatureStatusPollBackoffMultiplier: TimeInterval = 1.5
    private let signatureStatusPollTimeout: TimeInterval = 45
    private static let clusterHintOptionKeys = ["bigWalletCluster", "cluster"]
    private static let allowedPreflightCommitments = Set(["processed", "confirmed", "finalized"])

    private init() {}

    static func preparedSendOptions(from rawOptions: [String: Any]?) -> Result<PreparedSendOptions, SendTransactionError> {
        let options = rawOptions ?? [:]
        switch clusterHint(from: options) {
        case .failure(let error):
            return .failure(error)
        case .success(let clusterHint):
            let parsedConfirmationCommitment: Commitment?
            switch confirmationCommitment(from: options) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                parsedConfirmationCommitment = value
            }

            guard let rpcOptions = sanitizedRPCOptions(from: options) else {
                return .failure(.invalidSendOptions)
            }

            return .success(PreparedSendOptions(clusterHint: clusterHint,
                                                rpcOptions: rpcOptions,
                                                confirmationCommitment: parsedConfirmationCommitment))
        }
    }

    private static func clusterHint(from options: [String: Any]) -> Result<Cluster?, SendTransactionError> {
        var parsedHint: Cluster?
        for key in clusterHintOptionKeys {
            guard let value = options[key] else { continue }
            guard let rawValue = value as? String,
                  let cluster = Cluster(clusterHint: rawValue)
            else {
                return .failure(.invalidSendOptions)
            }

            if let parsedHint, parsedHint != cluster {
                return .failure(.invalidSendOptions)
            }
            parsedHint = cluster
        }

        return .success(parsedHint)
    }

    private static func confirmationCommitment(from options: [String: Any]) -> Result<Commitment?, SendTransactionError> {
        guard let value = options["commitment"] else { return .success(nil) }
        guard let rawValue = value as? String,
              let commitment = Commitment(rawValue: rawValue) else {
            return .failure(.invalidSendOptions)
        }
        return .success(commitment)
    }

    private static func sanitizedRPCOptions(from options: [String: Any]) -> [String: Any]? {
        var sanitizedOptions: [String: Any] = [
            "encoding": "base64",
            "skipPreflight": false,
        ]

        for (key, value) in options {
            switch key {
            case "encoding":
                continue
            case _ where clusterHintOptionKeys.contains(key):
                continue
            case "skipPreflight":
                guard let skipPreflight = value as? Bool, !skipPreflight else {
                    return nil
                }
            case "preflightCommitment":
                guard let commitment = value as? String,
                      allowedPreflightCommitments.contains(commitment) else {
                    return nil
                }
                sanitizedOptions[key] = commitment
            case "commitment":
                continue
            case "mode":
                guard let mode = value as? String, mode == "serial" else {
                    return nil
                }
                continue
            case "maxRetries", "minContextSlot":
                guard let intValue = nonNegativeInt(from: value) else {
                    return nil
                }
                sanitizedOptions[key] = intValue
            default:
                continue
            }
        }

        return sanitizedOptions
    }

    private static func nonNegativeInt(from value: Any) -> Int? {
        if value is Bool {
            return nil
        }

        if let intValue = value as? Int {
            return intValue >= 0 ? intValue : nil
        }

        guard let number = value as? NSNumber else {
            return nil
        }

        let doubleValue = number.doubleValue
        guard doubleValue >= 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue <= Double(Int.max)
        else {
            return nil
        }

        return number.intValue
    }

    func sign(message: String, asHex: Bool, privateKey: PrivateKey) -> String? {
        guard let messageData = decodeMessage(message, asHex: asHex) else { return nil }
        return sign(messageData: messageData, privateKey: privateKey)
    }

    func sign(messageData: Data, privateKey: PrivateKey) -> String? {
        return sign(digest: messageData, privateKey: privateKey)
    }

    func validationErrorForSigningTransaction(message: String, publicKey: String) -> SendTransactionError? {
        return validationError(for: preparedTransactionMessage(message: message, publicKey: publicKey))
    }

    func validationErrorForSigningTransaction(messageData: Data, publicKey: String) -> SendTransactionError? {
        return validationError(for: preparedTransactionMessage(messageData: messageData, publicKey: publicKey))
    }

    func decodeMessage(_ message: String, asHex: Bool) -> Data? {
        return asHex ? Data(hexString: message) : Base58.decodeNoCheck(string: message)
    }

    func preparedSerializedTransactionForSignAndSend(serializedTransaction: String,
                                                     publicKey: String) -> Result<PreparedSerializedTransaction, SendTransactionError> {
        return preparedSignAndSend(serializedTransaction: serializedTransaction, publicKey: publicKey).map { preparedTransaction in
            PreparedSerializedTransaction(approvalMessage: Base58.encodeNoCheck(data: preparedTransaction.parsedTransaction.messageData),
                                         preparedTransaction: preparedTransaction)
        }
    }

    func preparedLegacySignAndSendTransaction(message: String,
                                              publicKey: String) -> Result<PreparedLegacySignAndSendTransaction, SendTransactionError> {
        return preparedLegacySignAndSend(message: message, publicKey: publicKey).map { preparedTransaction in
            PreparedLegacySignAndSendTransaction(approvalMessage: message,
                                                messageData: preparedTransaction.messageData,
                                                parsedMessage: preparedTransaction.parsedMessage)
        }
    }

    func signAndSendTransaction(preparedSerializedTransaction: PreparedSerializedTransaction,
                                cluster: Cluster,
                                sendOptions: PreparedSendOptions,
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        switch signedTransactionForSignAndSend(preparedSerializedTransaction: preparedSerializedTransaction,
                                               privateKey: privateKey) {
        case .failure(let error):
            completion(.failure(error))
        case .success(let signedTransaction):
            sendTransaction(signed: signedTransaction, cluster: cluster, sendOptions: sendOptions, completion: completion)
        }
    }

    func signAndSendTransaction(preparedLegacyTransaction: PreparedLegacySignAndSendTransaction,
                                cluster: Cluster,
                                sendOptions: PreparedSendOptions,
                                privateKey: PrivateKey,
                                completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard let signedData = signatureData(digest: preparedLegacyTransaction.messageData, privateKey: privateKey),
              let raw = compileTransactionData(messageData: preparedLegacyTransaction.messageData,
                                               parsedMessage: preparedLegacyTransaction.parsedMessage,
                                               signatureData: signedData) else {
            completion(.failure(.invalidMessage))
            return
        }

        sendTransaction(signed: raw, cluster: cluster, sendOptions: sendOptions, completion: completion)
    }

    func signedTransactionForSignAndSend(preparedSerializedTransaction: PreparedSerializedTransaction,
                                         privateKey: PrivateKey) -> Result<String, SendTransactionError> {
        let prepared = preparedSerializedTransaction.preparedTransaction
        guard let signedData = signatureData(digest: prepared.parsedTransaction.messageData, privateKey: privateKey),
              let signedTransaction = compileTransactionData(transactionData: prepared.parsedTransaction.transactionData,
                                                             signerSignatureRange: prepared.signerSignatureRange,
                                                             signatureData: signedData) else {
            return .failure(.invalidMessage)
        }

        return .success(signedTransaction)
    }

    private func preparedLegacySignAndSend(message: String,
                                           publicKey: String) -> Result<(messageData: Data, parsedMessage: SolanaWireMessage), SendTransactionError> {
        switch preparedTransactionMessage(message: message, publicKey: publicKey) {
        case .failure(let error):
            return .failure(error)
        case .success(let prepared):
            let parsedMessage = prepared.parsedMessage

            // The bridge only carries message bytes for signAndSendTransaction, so
            // the wallet can safely assemble a full wire transaction only when it
            // owns the lone required signature.
            guard parsedMessage.requiredSignaturesCount == 1 else {
                return .failure(.unsupportedMultiSignature)
            }

            return .success(prepared)
        }
    }

    private func validationError<T>(for result: Result<T, SendTransactionError>) -> SendTransactionError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    private func preparedSignAndSend(serializedTransaction: String,
                                     publicKey: String) -> Result<PreparedSignAndSendTransaction, SendTransactionError> {
        switch parsedTransaction(serializedTransaction: serializedTransaction) {
        case .failure(let error):
            return .failure(error)
        case .success(let parsedTransaction):
            guard let signerIndex = signerIndex(in: parsedTransaction.parsedMessage, for: publicKey)
            else {
                return .failure(.invalidMessage)
            }

            guard requiredCosignerSignaturesArePresent(in: parsedTransaction,
                                                       excludingSignerAt: signerIndex)
            else {
                return .failure(.unsupportedMultiSignature)
            }

            guard let signerSignatureRange = signatureRange(in: parsedTransaction,
                                                            signatureIndex: signerIndex)
            else {
                return .failure(.invalidMessage)
            }

            return .success(PreparedSignAndSendTransaction(parsedTransaction: parsedTransaction,
                                                           signerSignatureRange: signerSignatureRange))
        }
    }

    private func createRequest(method: Method, cluster: Cluster, parameters: [Any]? = nil) -> URLRequest {
        let endpoint = RPCConfiguration().endpoint(for: cluster)
        var request = URLRequest(url: endpoint.url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"

        var dict: [String: Any] = [
            "method": method.rawValue,
            "id": 1,
            "jsonrpc": "2.0",
        ]

        if let parameters {
            dict["params"] = parameters
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed)
        return request
    }

    private func sendTransaction(signed: String,
                                 cluster: Cluster,
                                 sendOptions: PreparedSendOptions,
                                 completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        var parameters: [Any] = [signed]
        parameters.append(sendOptions.rpcOptions)

        performRequest(method: .sendTransaction, cluster: cluster, parameters: parameters) { (response: SendTransactionResponse?) in
            guard let response else {
                completion(.failure(.unknown))
                return
            }

            if let result = response.result {
                if let confirmationCommitment = sendOptions.confirmationCommitment {
                    self.confirmTransaction(signature: result,
                                            commitment: confirmationCommitment,
                                            cluster: cluster,
                                            deadline: Date().addingTimeInterval(self.signatureStatusPollTimeout),
                                            nextPollInterval: self.signatureStatusInitialPollInterval,
                                            lastStatusFailure: nil,
                                            completion: completion)
                } else {
                    completion(.success(result))
                }
            } else if let failure = response.failure {
                completion(.failure(failure))
            } else {
                completion(.failure(.unknown))
            }
        }
    }

    private func confirmTransaction(signature: String,
                                    commitment: Commitment,
                                    cluster: Cluster,
                                    deadline: Date,
                                    nextPollInterval: TimeInterval,
                                    lastStatusFailure: SendTransactionError?,
                                    completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        guard Date() <= deadline else {
            completion(.failure(lastStatusFailure ?? .confirmationTimedOut(signature: signature)))
            return
        }

        let parameters: [Any] = [
            [signature],
            ["searchTransactionHistory": true],
        ]
        performRequest(method: .getSignatureStatuses,
                       cluster: cluster,
                       parameters: parameters) { (response: SignatureStatusesResponse?) in
            guard let response else {
                self.scheduleConfirmationRetry(signature: signature,
                                               commitment: commitment,
                                               cluster: cluster,
                                               deadline: deadline,
                                               nextPollInterval: nextPollInterval,
                                               lastStatusFailure: lastStatusFailure,
                                               completion: completion)
                return
            }

            if let failure = response.failure {
                self.scheduleConfirmationRetry(signature: signature,
                                               commitment: commitment,
                                               cluster: cluster,
                                               deadline: deadline,
                                               nextPollInterval: nextPollInterval,
                                               lastStatusFailure: self.confirmationFailure(signature: signature,
                                                                                          failure: failure),
                                               completion: completion)
                return
            }

            guard let status = response.status else {
                self.scheduleConfirmationRetry(signature: signature,
                                               commitment: commitment,
                                               cluster: cluster,
                                               deadline: deadline,
                                               nextPollInterval: nextPollInterval,
                                               lastStatusFailure: nil,
                                               completion: completion)
                return
            }

            if let failure = status.failure {
                completion(.failure(self.confirmationFailure(signature: signature, failure: failure)))
                return
            }

            if status.satisfies(commitment) {
                completion(.success(signature))
                return
            }

            self.scheduleConfirmationRetry(signature: signature,
                                           commitment: commitment,
                                           cluster: cluster,
                                           deadline: deadline,
                                           nextPollInterval: nextPollInterval,
                                           lastStatusFailure: nil,
                                           completion: completion)
        }
    }

    private func scheduleConfirmationRetry(signature: String,
                                           commitment: Commitment,
                                           cluster: Cluster,
                                           deadline: Date,
                                           nextPollInterval: TimeInterval,
                                           lastStatusFailure: SendTransactionError?,
                                           completion: @escaping (Result<String, SendTransactionError>) -> Void) {
        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else {
            completion(.failure(lastStatusFailure ?? .confirmationTimedOut(signature: signature)))
            return
        }

        let delay = min(nextPollInterval, remainingTime)
        let followingPollInterval = min(nextPollInterval * signatureStatusPollBackoffMultiplier,
                                        signatureStatusMaxPollInterval)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.confirmTransaction(signature: signature,
                                    commitment: commitment,
                                    cluster: cluster,
                                    deadline: deadline,
                                    nextPollInterval: followingPollInterval,
                                    lastStatusFailure: lastStatusFailure,
                                    completion: completion)
        }
    }

    private func confirmationFailure(signature: String, failure: SendTransactionError) -> SendTransactionError {
        switch failure {
        case .rpcError(let message, let code):
            return .confirmationFailed(signature: signature,
                                       message: message,
                                       code: code)
        case .confirmationFailed, .confirmationTimedOut:
            return failure
        case .blockhashNotFound:
            return .confirmationFailed(signature: signature,
                                       message: Strings.solanaBlockhashNotFound,
                                       code: -32003)
        case .invalidMessage, .invalidSendOptions, .unsupportedMultiSignature, .unknown:
            return .confirmationFailed(signature: signature,
                                       message: Strings.failedToSend,
                                       code: nil)
        }
    }

    private func sign(digest: Data, privateKey: PrivateKey) -> String? {
        guard let signedData = signatureData(digest: digest, privateKey: privateKey) else { return nil }
        return Base58.encodeNoCheck(data: signedData)
    }

    private func signatureData(digest: Data, privateKey: PrivateKey) -> Data? {
        return privateKey.sign(digest: digest, curve: CoinType.solana.curve)
    }

    private func compileTransactionData(messageData: Data,
                                        parsedMessage: SolanaWireMessage,
                                        signatureData: Data) -> String? {
        guard signatureData.count == signatureLength
        else { return nil }

        let placeholderSignature = Data(repeating: 0, count: signatureLength)

        var result = Data.encodeLength(parsedMessage.requiredSignaturesCount)
        result += signatureData
        for _ in 0..<max(parsedMessage.requiredSignaturesCount - 1, 0) {
            result += placeholderSignature
        }

        result += messageData
        return result.base64EncodedString()
    }

    private func compileTransactionData(transactionData: Data,
                                        signerSignatureRange: Range<Data.Index>,
                                        signatureData: Data) -> String? {
        guard signatureData.count == signatureLength
        else { return nil }

        var updatedTransaction = transactionData
        updatedTransaction.replaceSubrange(signerSignatureRange, with: signatureData)
        return updatedTransaction.base64EncodedString()
    }

    private func performRequest<Response: Decodable>(method: Method,
                                                     cluster: Cluster,
                                                     parameters: [Any]? = nil,
                                                     completion: @escaping (Response?) -> Void) {
        let request = createRequest(method: method, cluster: cluster, parameters: parameters)
        let dataTask = urlSession.dataTask(with: request) { data, _, _ in
            guard let data else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let response = try? JSONDecoder().decode(Response.self, from: data)
            DispatchQueue.main.async {
                completion(response)
            }
        }
        dataTask.resume()
    }

    private func parsedTransaction(serializedTransaction: String) -> Result<ParsedTransaction, SendTransactionError> {
        guard let transactionData = Base58.decodeNoCheck(string: serializedTransaction),
              let signaturesCount = transactionData.decodeLength(startingAt: transactionData.startIndex)
        else {
            return .failure(.invalidMessage)
        }

        guard signaturesCount.length > 0 else {
            return .failure(.invalidMessage)
        }

        let (signaturesByteLength, didOverflow) = signaturesCount.length.multipliedReportingOverflow(by: signatureLength)
        guard !didOverflow,
              let messageStartIndex = transactionData.index(signaturesCount.nextIndex,
                                                            offsetBy: signaturesByteLength,
                                                            limitedBy: transactionData.endIndex)
        else {
            return .failure(.invalidMessage)
        }

        let messageRange = messageStartIndex..<transactionData.endIndex
        let messageData = transactionData.subdata(in: messageRange)
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData),
              parsedMessage.requiredSignaturesCount == signaturesCount.length
        else {
            return .failure(.invalidMessage)
        }

        return .success(ParsedTransaction(transactionData: transactionData,
                                          messageData: messageData,
                                          messageRange: messageRange,
                                          parsedMessage: parsedMessage,
                                          signaturesStartIndex: signaturesCount.nextIndex))
    }

    private func requiredCosignerSignaturesArePresent(in parsedTransaction: ParsedTransaction,
                                                      excludingSignerAt signerIndex: Int) -> Bool {
        for signatureIndex in 0..<parsedTransaction.parsedMessage.requiredSignaturesCount where signatureIndex != signerIndex {
            guard let range = signatureRange(in: parsedTransaction, signatureIndex: signatureIndex)
            else { return false }

            if parsedTransaction.transactionData[range].allSatisfy({ $0 == 0 }) {
                return false
            }
        }

        return true
    }

    private func signatureRange(in parsedTransaction: ParsedTransaction,
                                signatureIndex: Int) -> Range<Data.Index>? {
        guard signatureIndex >= 0,
              signatureIndex < parsedTransaction.parsedMessage.requiredSignaturesCount
        else {
            return nil
        }

        let (signatureOffset, didOverflow) = signatureIndex.multipliedReportingOverflow(by: signatureLength)
        guard !didOverflow,
              let signatureStart = parsedTransaction.transactionData.index(parsedTransaction.signaturesStartIndex,
                                                                           offsetBy: signatureOffset,
                                                                           limitedBy: parsedTransaction.messageRange.lowerBound),
              let signatureEnd = parsedTransaction.transactionData.index(signatureStart,
                                                                         offsetBy: signatureLength,
                                                                         limitedBy: parsedTransaction.messageRange.lowerBound)
        else {
            return nil
        }

        return signatureStart..<signatureEnd
    }

    private func preparedTransactionMessage(message: String,
                                           publicKey: String) -> Result<(messageData: Data, parsedMessage: SolanaWireMessage), SendTransactionError> {
        guard let messageData = decodeMessage(message, asHex: false) else {
            return .failure(.invalidMessage)
        }

        return preparedTransactionMessage(messageData: messageData, publicKey: publicKey)
    }

    private func preparedTransactionMessage(messageData: Data,
                                            publicKey: String) -> Result<(messageData: Data, parsedMessage: SolanaWireMessage), SendTransactionError> {
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData) else {
            return .failure(.invalidMessage)
        }

        guard parsedMessage.requiredSignaturesCount > 0,
              signerIndex(in: parsedMessage, for: publicKey) != nil
        else {
            return .failure(.invalidMessage)
        }

        return .success((messageData, parsedMessage))
    }

    private func signerIndex(in parsedMessage: SolanaWireMessage, for publicKey: String) -> Int? {
        guard let publicKeyData = Base58.decodeNoCheck(string: publicKey),
              publicKeyData.count == publicKeyLength
        else {
            return nil
        }

        return parsedMessage.accountKeys
            .prefix(parsedMessage.requiredSignaturesCount)
            .firstIndex(of: publicKeyData)
    }

}

private extension String {

    func containsIgnoringCase(_ string: String) -> Bool {
        return range(of: string, options: .caseInsensitive) != nil
    }

    func trimmingTrailingZeros(keepingAtLeastOneDecimal: Bool) -> String {
        var result = self
        while result.last == "0" {
            result.removeLast()
        }
        if keepingAtLeastOneDecimal && result.isEmpty {
            return "0"
        }
        return result
    }

}

extension Data {

    fileprivate func decodeLength(startingAt startIndex: Data.Index) -> (length: Int, nextIndex: Data.Index)? {
        guard startIndex < endIndex else { return nil }

        var length: UInt = 0
        var shift = 0
        var index = startIndex

        while index < endIndex {
            let element = self[index]
            index = self.index(after: index)

            guard shift < UInt.bitWidth else { return nil }
            let multiplier = UInt(1) << shift
            let (component, componentOverflow) = UInt(element & 0x7f).multipliedReportingOverflow(by: multiplier)
            guard !componentOverflow else { return nil }
            let (newLength, didOverflow) = length.addingReportingOverflow(component)
            guard !didOverflow else { return nil }
            length = newLength

            if element & 0x80 == 0 {
                guard let intLength = Int(exactly: length) else { return nil }
                return (length: intLength, nextIndex: index)
            }

            shift += 7
        }

        return nil
    }

    static func encodeLength(_ length: Int) -> Data {
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

    fileprivate func solanaUInt32LE(at offset: Int) -> UInt32? {
        var value: UInt32 = 0
        for byteOffset in 0..<4 {
            guard let byte = byte(at: offset + byteOffset) else { return nil }
            value |= UInt32(byte) << (byteOffset * 8)
        }
        return value
    }

    fileprivate func solanaUInt64LE(at offset: Int) -> UInt64? {
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
