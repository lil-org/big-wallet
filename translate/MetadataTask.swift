// ∅ 2024 lil org

import Foundation

struct MetadataTask: AI.Task {
    
    let model: AI.Model
    let metadataKind: MetadataKind
    let language: Language
    let englishText: String
    let russianText: String
    
    var description: String {
        return "\(language.name) \(metadataKind.fileName)"
    }
    
    var prompt: String {
        let metadataName: String
        let clarifications: String
        
        switch metadataKind {
        case .description:
            metadataName = "app description"
        case .keywords:
            metadataName = "app store keywords"
        case .name:
            metadataName = "app name"
        case .subtitle:
            metadataName = "app store page subtitle"
        case .promotionalText:
            metadataName = "app store promotional text"
        case .releaseNotes:
            metadataName = "app release notes"
        default:
            metadataName = "text"
        }
        
        switch metadataKind {
        case .name, .subtitle:
            clarifications = """
            feel free to tune it to make \(language.name) version sound natural.
            
            make sure the translated version communicates the same message.
            
            keep it lowercased if possible.
            """
        case .keywords:
            clarifications = """
            make sure the output keywords are no longer than 100 chars.
            
            separate keywords with an english comma.
            
            do not add whitespaces after comma — in order to fit more keywords in.
            
            feel free to slightly change and reorder the words used.
            
            the output should be good to be used as app store keywords.
            
            make sure the output text is no longer than 100 chars. keywords must fit in 100 chars.
            """
        default:
            clarifications = """
            feel free to tune it to make \(language.name) version sound natural.
            
            make sure the translated version communicates the same message.
            
            keep formatting, capitalization, and punctuation style close to the original.
            """
        }
        
        // TODO: subtitle cannot be longer than 30 characters
        
        let output = """
        translate the \(metadataName) to \(language.name).
        
        \(clarifications)
        
        keep it simple and straightforward.
        
        use english and russian texts below as a reference.
        
        english:
        "\(englishText)"
        
        russian:
        "\(russianText)"
        
        "big wallet" and "lil org" are names that should not be translated, keep them as is.
        
        respond only with a \(language.name) version. do not add anything else to the response.
        """
        
        return output
    }
    
    var wasCompletedBefore: Bool {
        if let data = try? Data(contentsOf: hashURL),
           let text = String(data: data, encoding: .utf8) {
            return hash == text
        } else {
            return false
        }
    }
    
    func storeAsCompleted() {
        let data = hash.data(using: .utf8)!
        try! data.write(to: hashURL)
    }
    
    private var hashURL: URL {
        return URL(fileURLWithPath: projectDir + "/translate/latest/" + "\(language.metadataLocalizationKey)-\(metadataKind.fileName)")
    }
    
}
