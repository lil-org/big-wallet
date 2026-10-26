import Foundation
import WalletDomain

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

    private static let systemProgramID = WalletCrypto.base58Decode(string: "11111111111111111111111111111111")!
    private static let tokenProgramID = WalletCrypto.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!
    private static let token2022ProgramID = WalletCrypto.base58Decode(string: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")!
    private static let associatedTokenProgramID = WalletCrypto.base58Decode(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!
    private static let computeBudgetProgramID = WalletCrypto.base58Decode(string: "ComputeBudget111111111111111111111111111111")!
    private static let memoProgramID = WalletCrypto.base58Decode(string: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")!
    private static let legacyMemoProgramID = WalletCrypto.base58Decode(string: "Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo")!

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
        return approvalMessage(rawMessages: encodedMessages) { index in
            approvalMessage(messageData: messageDataList[index],
                            encodedMessages: [encodedMessages[index]])
        }
    }

    static func approvalMessage(encodedMessages: [String],
                                preparedMessages: [SolanaPreparedTransactionMessage]) -> String {
        guard encodedMessages.count == preparedMessages.count else {
            return rawApprovalMessage(messages: encodedMessages)
        }
        return approvalMessage(rawMessages: encodedMessages) { index in
            let preparedMessage = preparedMessages[index]
            return approvalMessage(parsedMessage: preparedMessage.parsedMessage,
                                   messageData: preparedMessage.messageData,
                                   encodedMessages: [encodedMessages[index]])
        }
    }

    private static func approvalMessage(rawMessages: [String],
                                        renderMessage: (Int) -> String) -> String {
        guard !rawMessages.isEmpty else {
            return rawApprovalMessage(messages: rawMessages)
        }
        guard rawMessages.count != 1 else {
            return renderMessage(0)
        }

        return rawMessages.indices.map { index in
            return "Transaction \(index + 1)\n\n" + renderMessage(index)
        }.joined(separator: "\n\n")
    }

    private static func approvalMessage(parsedMessage: SolanaWireMessage,
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
        return AuthorityStrings.rawSolanaTransactionWarning + "\n\n" + rawDataSection(messages: messages)
    }

    private static func summarySection(message: SolanaWireMessage, messageData: Data) -> String {
        var lines = ["Solana transaction"]
        lines.append("Version: \(message.version == .legacy ? "Legacy" : "v0")")
        if let feePayer = message.feePayer {
            lines.append("Fee payer: \(address(feePayer))")
        }
        lines.append("Recent blockhash: \(WalletCrypto.base58Encode(data: messageData.subdata(in: message.blockhashRange)))")
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
        return WalletCrypto.base58Encode(data: data)
    }

    private static func shortHex(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        let prefix = data.prefix(8)
        let suffix = data.count > prefix.count ? "..." : ""
        return "0x" + WalletCrypto.hexString(data: prefix) + suffix
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
        return AuthorityStrings.data + ":\n\n" + messages.joined(separator: "\n\n")
    }
}

struct SolanaSigner: Sendable {
    private static let signatureLength = 64
    private let publicKeyLength = 32
    private static let clusterHintOptionKeys = ["bigWalletCluster", "cluster"]

    static func preparedSendOptions(from rawOptions: [String: Any]?) -> Result<Solana.PreparedSendOptions, Solana.SendTransactionError> {
        let options = rawOptions ?? [:]
        switch clusterHint(from: options) {
        case .failure(let error):
            return .failure(error)
        case .success(let clusterHint):
            let parsedConfirmationCommitment: Solana.Commitment?
            switch confirmationCommitment(from: options) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                parsedConfirmationCommitment = value
            }

            var preflightCommitment: Solana.Commitment?
            var maxRetries: Int?
            var minContextSlot: Int?
            for (key, value) in options {
                switch key {
                case "skipPreflight":
                    guard let skipPreflight = value as? Bool, !skipPreflight else {
                        return .failure(.invalidSendOptions)
                    }
                case "preflightCommitment":
                    guard let rawValue = value as? String,
                          let commitment = Solana.Commitment(rawValue: rawValue) else {
                        return .failure(.invalidSendOptions)
                    }
                    preflightCommitment = commitment
                case "mode":
                    guard let mode = value as? String, mode == "serial" else {
                        return .failure(.invalidSendOptions)
                    }
                case "maxRetries":
                    guard let value = nonNegativeInt(from: value) else {
                        return .failure(.invalidSendOptions)
                    }
                    maxRetries = value
                case "minContextSlot":
                    guard let value = nonNegativeInt(from: value) else {
                        return .failure(.invalidSendOptions)
                    }
                    minContextSlot = value
                default:
                    continue
                }
            }

            return .success(Solana.PreparedSendOptions(
                clusterHint: clusterHint,
                preflightCommitment: preflightCommitment,
                maxRetries: maxRetries,
                minContextSlot: minContextSlot,
                confirmationCommitment: parsedConfirmationCommitment
            ))
        }
    }

    private static func clusterHint(from options: [String: Any]) -> Result<Solana.Cluster?, Solana.SendTransactionError> {
        var parsedHint: Solana.Cluster?
        for key in clusterHintOptionKeys {
            guard let value = options[key] else { continue }
            guard let rawValue = value as? String,
                  let cluster = Solana.Cluster(clusterHint: rawValue)
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

    private static func confirmationCommitment(from options: [String: Any]) -> Result<Solana.Commitment?, Solana.SendTransactionError> {
        guard let value = options["commitment"] else { return .success(nil) }
        guard let rawValue = value as? String,
              let commitment = Solana.Commitment(rawValue: rawValue) else {
            return .failure(.invalidSendOptions)
        }
        return .success(commitment)
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

    func sign(message: String, asHex: Bool, privateKey: WalletPrivateKey) -> String? {
        guard let messageData = decodeMessage(message, asHex: asHex) else { return nil }
        return Self.sign(messageData: messageData, privateKey: privateKey)
    }

    static func sign(messageData: Data, privateKey: WalletPrivateKey) -> String? {
        guard let signedData = signatureData(
            digest: messageData,
            privateKey: privateKey
        ) else { return nil }
        return WalletCrypto.base58Encode(data: signedData)
    }

    static func sign(
        messageDataList: [Data],
        privateKey: WalletPrivateKey
    ) -> [String]? {
        guard let signatureDataList = privateKey.sign(digests: messageDataList, coin: .solana) else { return nil }
        return signatureDataList.map { WalletCrypto.base58Encode(data: $0) }
    }

    func validationErrorForSigningTransaction(message: String, publicKey: String) -> Solana.SendTransactionError? {
        return validationError(for: preparedTransactionMessage(message: message, publicKey: publicKey))
    }

    func preparedTransactionMessageForSigning(message: String,
                                              publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        return preparedTransactionMessage(message: message, publicKey: publicKey)
    }

    func decodeMessage(_ message: String, asHex: Bool) -> Data? {
        return asHex ? WalletCrypto.hexData(string: message) : WalletCrypto.base58Decode(string: message)
    }

    func decodeTransactionMessage(_ message: String) -> Data? {
        guard Self.isValidBase58EncodedWirePayload(message),
              let messageData = decodeMessage(message, asHex: false),
              messageData.count <= Solana.maxWirePayloadLength else { return nil }
        return messageData
    }

    func preparedSerializedTransactionForSignAndSend(serializedTransaction: String,
                                                     publicKey: String) -> Result<Solana.PreparedSerializedTransaction, Solana.SendTransactionError> {
        return preparedSignAndSend(serializedTransaction: serializedTransaction, publicKey: publicKey).map { preparedTransaction in
            Solana.PreparedSerializedTransaction(approvalMessage: WalletCrypto.base58Encode(data: preparedTransaction.parsedTransaction.messageData),
                                         preparedTransaction: preparedTransaction)
        }
    }

    func preparedLegacySignAndSendTransaction(message: String,
                                              publicKey: String) -> Result<Solana.PreparedLegacySignAndSendTransaction, Solana.SendTransactionError> {
        return preparedLegacySignAndSend(message: message, publicKey: publicKey).map { preparedTransaction in
            Solana.PreparedLegacySignAndSendTransaction(approvalMessage: message,
                                                preparedMessage: preparedTransaction)
        }
    }

    static func signedTransactionForSignAndSend(
        preparedSerializedTransaction: Solana.PreparedSerializedTransaction,
        privateKey: WalletPrivateKey
    ) -> String? {
        let prepared = preparedSerializedTransaction.preparedTransaction
        guard let signedData = signatureData(digest: prepared.parsedTransaction.messageData, privateKey: privateKey),
              let signedTransaction = compileTransactionData(transactionData: prepared.parsedTransaction.transactionData,
                                                             signerSignatureRange: prepared.signerSignatureRange,
                                                             signatureData: signedData) else {
            return nil
        }

        return signedTransaction
    }

    static func signedTransactionForSignAndSend(
        preparedLegacyTransaction: Solana.PreparedLegacySignAndSendTransaction,
        privateKey: WalletPrivateKey
    ) -> String? {
        let preparedMessage = preparedLegacyTransaction.preparedMessage
        guard let signedData = signatureData(
                  digest: preparedMessage.messageData,
                  privateKey: privateKey
              ),
              let signedTransaction = compileTransactionData(
                  messageData: preparedMessage.messageData,
                  parsedMessage: preparedMessage.parsedMessage,
                  signatureData: signedData
              ) else {
            return nil
        }
        return signedTransaction
    }

    static func transactionSignature(signedTransaction: String) -> String? {
        guard let transactionData = Data(base64Encoded: signedTransaction),
              let signaturesCount = transactionData.decodeLength(
                  startingAt: transactionData.startIndex
              ),
              signaturesCount.length > 0 else { return nil }
        let (signaturesByteCount, didOverflow) = signaturesCount.length
            .multipliedReportingOverflow(by: signatureLength)
        guard !didOverflow,
              transactionData.distance(
                  from: signaturesCount.nextIndex,
                  to: transactionData.endIndex
              ) > signaturesByteCount else { return nil }
        let signatureEnd = transactionData.index(
            signaturesCount.nextIndex,
            offsetBy: signatureLength
        )
        let signature = transactionData.subdata(
            in: signaturesCount.nextIndex..<signatureEnd
        )
        guard signature.contains(where: { $0 != 0 }) else { return nil }
        return WalletCrypto.base58Encode(data: signature)
    }

    private func preparedLegacySignAndSend(message: String,
                                           publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        switch preparedTransactionMessage(message: message, publicKey: publicKey) {
        case .failure(let error):
            return .failure(error)
        case .success(let prepared):
            let parsedMessage = prepared.parsedMessage

            guard parsedMessage.requiredSignaturesCount == 1 else {
                return .failure(.unsupportedMultiSignature)
            }

            return .success(prepared)
        }
    }

    private func validationError<T>(for result: Result<T, Solana.SendTransactionError>) -> Solana.SendTransactionError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    private func preparedSignAndSend(serializedTransaction: String,
                                     publicKey: String) -> Result<Solana.PreparedSignAndSendTransaction, Solana.SendTransactionError> {
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

            return .success(Solana.PreparedSignAndSendTransaction(parsedTransaction: parsedTransaction,
                                                           signerSignatureRange: signerSignatureRange))
        }
    }

    private static func signatureData(digest: Data, privateKey: WalletPrivateKey) -> Data? {
        return privateKey.sign(digest: digest, coin: .solana)
    }

    private static func compileTransactionData(messageData: Data,
                                               parsedMessage: SolanaWireMessage,
                                               signatureData: Data) -> String? {
        guard signatureData.count == Self.signatureLength
        else { return nil }

        let placeholderSignature = Data(repeating: 0, count: Self.signatureLength)
        let signatureCountData = Data.encodeLength(parsedMessage.requiredSignaturesCount)
        let placeholderCount = max(parsedMessage.requiredSignaturesCount - 1, 0)

        var result = Data()
        result.reserveCapacity(signatureCountData.count + signatureData.count + placeholderCount * Self.signatureLength + messageData.count)
        result.append(signatureCountData)
        result.append(signatureData)
        for _ in 0..<placeholderCount {
            result.append(placeholderSignature)
        }

        result.append(messageData)
        return result.base64EncodedString()
    }

    private static func compileTransactionData(transactionData: Data,
                                               signerSignatureRange: Range<Data.Index>,
                                               signatureData: Data) -> String? {
        guard signatureData.count == Self.signatureLength
        else { return nil }

        var updatedTransaction = transactionData
        updatedTransaction.replaceSubrange(signerSignatureRange, with: signatureData)
        return updatedTransaction.base64EncodedString()
    }

    private func parsedTransaction(serializedTransaction: String) -> Result<Solana.ParsedTransaction, Solana.SendTransactionError> {
        guard Self.isValidBase58EncodedWirePayload(serializedTransaction) else {
            return .failure(.invalidMessage)
        }

        guard let transactionData = WalletCrypto.base58Decode(string: serializedTransaction),
              transactionData.count <= Solana.maxWirePayloadLength,
              let signaturesCount = transactionData.decodeLength(startingAt: transactionData.startIndex)
        else {
            return .failure(.invalidMessage)
        }

        guard signaturesCount.length > 0 else {
            return .failure(.invalidMessage)
        }

        let (signaturesByteLength, didOverflow) = signaturesCount.length.multipliedReportingOverflow(by: Self.signatureLength)
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

        return .success(Solana.ParsedTransaction(transactionData: transactionData,
                                          messageData: messageData,
                                          messageRange: messageRange,
                                          parsedMessage: parsedMessage,
                                          signaturesStartIndex: signaturesCount.nextIndex))
    }

    private func requiredCosignerSignaturesArePresent(in parsedTransaction: Solana.ParsedTransaction,
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

    private func signatureRange(in parsedTransaction: Solana.ParsedTransaction,
                                signatureIndex: Int) -> Range<Data.Index>? {
        guard signatureIndex >= 0,
              signatureIndex < parsedTransaction.parsedMessage.requiredSignaturesCount
        else {
            return nil
        }

        let (signatureOffset, didOverflow) = signatureIndex.multipliedReportingOverflow(by: Self.signatureLength)
        guard !didOverflow,
              let signatureStart = parsedTransaction.transactionData.index(parsedTransaction.signaturesStartIndex,
                                                                           offsetBy: signatureOffset,
                                                                           limitedBy: parsedTransaction.messageRange.lowerBound),
              let signatureEnd = parsedTransaction.transactionData.index(signatureStart,
                                                                         offsetBy: Self.signatureLength,
                                                                         limitedBy: parsedTransaction.messageRange.lowerBound)
        else {
            return nil
        }

        return signatureStart..<signatureEnd
    }

    private func preparedTransactionMessage(message: String,
                                           publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        guard let messageData = decodeTransactionMessage(message) else {
            return .failure(.invalidMessage)
        }

        return preparedTransactionMessage(messageData: messageData, publicKey: publicKey)
    }

    private func preparedTransactionMessage(messageData: Data,
                                            publicKey: String) -> Result<SolanaPreparedTransactionMessage, Solana.SendTransactionError> {
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData) else {
            return .failure(.invalidMessage)
        }

        guard parsedMessage.requiredSignaturesCount > 0,
              signerIndex(in: parsedMessage, for: publicKey) != nil
        else {
            return .failure(.invalidMessage)
        }

        return .success(SolanaPreparedTransactionMessage(messageData: messageData,
                                                         parsedMessage: parsedMessage))
    }

    private func signerIndex(in parsedMessage: SolanaWireMessage, for publicKey: String) -> Int? {
        guard let publicKeyData = WalletCrypto.base58Decode(string: publicKey),
              publicKeyData.count == publicKeyLength
        else {
            return nil
        }

        return parsedMessage.accountKeys
            .prefix(parsedMessage.requiredSignaturesCount)
            .firstIndex(of: publicKeyData)
    }

    private static func isValidBase58EncodedWirePayload(_ payload: String) -> Bool {
        return payload.utf8.count <= Solana.maxBase58EncodedWirePayloadLength
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

