import Foundation

public enum SolanaApprovalTextSanitizer {
    private static let unsafeFormatScalars = CharacterSet(charactersIn: "\u{061c}\u{200b}\u{200c}\u{200d}\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{feff}")

    public static func inline(_ text: String, maxLength: Int = 500) -> String {
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

public enum SolanaTransactionSummaryFormatter {
    public struct Labels: Sendable {
        public let rawTransactionWarning: String
        public let data: String

        public init(rawTransactionWarning: String, data: String) {
            self.rawTransactionWarning = rawTransactionWarning
            self.data = data
        }

        public static let english = Labels(rawTransactionWarning: "Raw Solana transaction. Big Wallet cannot display decoded instructions for this request. Only approve if you trust this website and expected this transaction.", data: "Data")
    }

    private struct InstructionSummary {
        let title: String
        let details: [String]
        let riskNotes: [String]
        let isUnknown: Bool
    }

    private static let systemProgramID = WalletEncoding.base58Decode(string: "11111111111111111111111111111111")!
    private static let tokenProgramID = WalletEncoding.base58Decode(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!
    private static let token2022ProgramID = WalletEncoding.base58Decode(string: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")!
    private static let associatedTokenProgramID = WalletEncoding.base58Decode(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!
    private static let computeBudgetProgramID = WalletEncoding.base58Decode(string: "ComputeBudget111111111111111111111111111111")!
    private static let memoProgramID = WalletEncoding.base58Decode(string: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")!
    private static let legacyMemoProgramID = WalletEncoding.base58Decode(string: "Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo")!

    public static func approvalMessage(messageData: Data, encodedMessages: [String], labels: Labels = .english) -> String {
        guard let parsedMessage = SolanaWireMessageParser.parse(messageData) else {
            return rawApprovalMessage(messages: encodedMessages, labels: labels)
        }

        return approvalMessage(parsedMessage: parsedMessage,
                               messageData: messageData,
                               encodedMessages: encodedMessages, labels: labels)
    }

    public static func approvalMessage(encodedMessages: [String], messageDataList: [Data], labels: Labels = .english) -> String {
        guard encodedMessages.count == messageDataList.count else {
            return rawApprovalMessage(messages: encodedMessages, labels: labels)
        }
        return approvalMessage(rawMessages: encodedMessages, labels: labels) { index in
            approvalMessage(messageData: messageDataList[index],
                            encodedMessages: [encodedMessages[index]], labels: labels)
        }
    }

    public static func approvalMessage(encodedMessages: [String],
                                preparedMessages: [SolanaPreparedTransactionMessage], labels: Labels = .english) -> String {
        guard encodedMessages.count == preparedMessages.count else {
            return rawApprovalMessage(messages: encodedMessages, labels: labels)
        }
        return approvalMessage(rawMessages: encodedMessages, labels: labels) { index in
            let preparedMessage = preparedMessages[index]
            return approvalMessage(parsedMessage: preparedMessage.parsedMessage,
                                   messageData: preparedMessage.messageData,
                                   encodedMessages: [encodedMessages[index]], labels: labels)
        }
    }

    private static func approvalMessage(rawMessages: [String], labels: Labels,
                                        renderMessage: (Int) -> String) -> String {
        guard !rawMessages.isEmpty else {
            return rawApprovalMessage(messages: rawMessages, labels: labels)
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
                                        encodedMessages: [String], labels: Labels) -> String {
        let summaries = parsedMessage.instructions.map { instruction in
            instructionSummary(instruction: instruction, message: parsedMessage)
        }

        var sections = [summarySection(message: parsedMessage, messageData: messageData)]
        sections.append(actionsSection(summaries: summaries))
        let riskNotes = riskNotes(message: parsedMessage, summaries: summaries)
        if !riskNotes.isEmpty {
            sections.append((["Risk notes"] + riskNotes.map { "- \($0)" }).joined(separator: "\n"))
        }
        sections.append(rawDataSection(messages: encodedMessages, labels: labels))
        return sections.joined(separator: "\n\n")
    }

    public static func rawApprovalMessage(messages: [String], labels: Labels = .english) -> String {
        return labels.rawTransactionWarning + "\n\n" + rawDataSection(messages: messages, labels: labels)
    }

    private static func summarySection(message: SolanaWireMessage, messageData: Data) -> String {
        var lines = ["Solana transaction"]
        lines.append("Version: \(message.version == .legacy ? "Legacy" : "v0")")
        if let feePayer = message.feePayer {
            lines.append("Fee payer: \(address(feePayer))")
        }
        lines.append("Recent blockhash: \(WalletEncoding.base58Encode(data: messageData.subdata(in: message.blockhashRange)))")
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
        return WalletEncoding.base58Encode(data: data)
    }

    private static func shortHex(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        let prefix = data.prefix(8)
        let suffix = data.count > prefix.count ? "..." : ""
        return "0x" + WalletEncoding.hexString(data: prefix) + suffix
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

    private static func rawDataSection(messages: [String], labels: Labels) -> String {
        return labels.data + ":\n\n" + messages.joined(separator: "\n\n")
    }
}


private extension String {

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

