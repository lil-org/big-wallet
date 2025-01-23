// ∅ 2025 lil org

import Foundation

func translateAppStoreMetadata(_ model: AI.Model) {
    var tasks = [MetadataTask]()
    
    for metadataKind in MetadataKind.allCases {
        let englishText = originalMetadata(kind: metadataKind, language: .english)
        let russianText = originalMetadata(kind: metadataKind, language: .russian)
        let englishOverride = overrideMetadata(kind: metadataKind, language: .english) ?? englishText
        
        write(englishText, englishOverride: englishOverride, metadataKind: metadataKind, language: .english)
        write(russianText, englishOverride: englishOverride, metadataKind: metadataKind, language: .russian)
        
        if let russianOverrideText = overrideMetadata(kind: metadataKind, language: .russian) {
            write(russianOverrideText, englishOverride: englishOverride, metadataKind: metadataKind, language: .russian)
        }
        
        if let englishOverrideText = overrideMetadata(kind: metadataKind, language: .english) {
            write(englishOverrideText, englishOverride: englishOverride, metadataKind: metadataKind, language: .english)
        }
        
        let notEmpty = !englishText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        for language in Language.allCases where language != .english && language != .russian {
            if metadataKind.toTranslate && notEmpty {
                let task = MetadataTask(model: model, metadataKind: metadataKind, language: language, englishText: englishText, russianText: russianText, englishOverride: englishOverride)
                if !task.wasCompletedBefore {
                    tasks.append(task)
                }
            } else {
                write(englishText, englishOverride: englishOverride, metadataKind: metadataKind, language: language)
            }
        }
    }
    
    var finalTasksCount = tasks.count
    for task in tasks {
        AI.translate(task: task) { translation in
            write(translation, englishOverride: task.englishOverride, metadataKind: task.metadataKind, language: task.language)
            task.storeAsCompleted()
            finalTasksCount -= 1
            if finalTasksCount == 0 {
                semaphore.signal()
            }
        }
    }
    
    if !tasks.isEmpty {
        semaphore.wait()
    }
}

func read(metadataKind: MetadataKind, language: Language) -> String {
    let url = url(metadataKind: metadataKind, language: language)
    return read(url: url)
}

func read(url: URL) -> String {
    let data = try! Data(contentsOf: url)
    let text = String(data: data, encoding: .utf8)!
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func write(_ newValue: String, englishOverride: String, metadataKind: MetadataKind, language: Language) {
    var toWrite: String
    if metadataKind == .subtitle && newValue.count > 30 {
        toWrite = englishOverride
    } else if metadataKind == .keywords && newValue.count > 100 {
        toWrite = englishOverride
    } else {
        toWrite = newValue
        
        let doNotModifyLanguages: [Language] = [.arabic, .hebrew, .hindi, .chinese, .japanese, .korean, .thai, .vietnamese, .malay, .indonesian]
        if metadataKind == .subtitle && toWrite.count < 30 && englishOverride.hasSuffix(".") && !toWrite.hasSuffix(".") && !doNotModifyLanguages.contains(language) {
            toWrite += "."
        }
    }
    
    let url = url(metadataKind: metadataKind, language: language)
    let data = toWrite.data(using: .utf8)!
    try! data.write(to: url)
}

func originalMetadata(kind: MetadataKind, language: Language) -> String {
    let suffix = kind.toTranslate && language == .russian ? "_ru" : ""
    let url = URL(fileURLWithPath: projectDir + "/app_store/" + "\(kind.fileName)\(suffix).txt")
    return read(url: url)
}

func overrideMetadata(kind: MetadataKind, language: Language) -> String? {
    let suffix = (kind.toTranslate && language == .russian ? "_ru" : "") + "_override"
    let url = URL(fileURLWithPath: projectDir + "/app_store/" + "\(kind.fileName)\(suffix).txt")
    if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        return nil
    }
}

func url(metadataKind: MetadataKind, language: Language) -> URL {
    return URL(fileURLWithPath: projectDir + "/fastlane/metadata/" + "\(language.metadataLocalizationKey)/\(metadataKind.fileName).txt")
}

