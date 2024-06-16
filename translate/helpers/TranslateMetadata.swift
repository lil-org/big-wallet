// ∅ 2024 lil org

import Foundation

func translateAppStoreMetadata(_ model: AI.Model) {
    var tasks = [MetadataTask]()
    
    for metadataKind in MetadataKind.allCases {
        let englishText = originalMetadata(kind: metadataKind, language: .english)
        let russianText = originalMetadata(kind: metadataKind, language: .russian)
        write(englishText, metadataKind: metadataKind, language: .english)
        write(russianText, metadataKind: metadataKind, language: .russian)
        let notEmpty = !englishText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        for language in Language.allCases where language != .english && language != .russian {
            if metadataKind.toTranslate && notEmpty {
                let task = MetadataTask(model: model, metadataKind: metadataKind, language: language, englishText: englishText, russianText: russianText)
                if !task.wasCompletedBefore {
                    tasks.append(task)
                }
            } else {
                write(englishText, metadataKind: metadataKind, language: language)
            }
        }
    }
    
    var finalTasksCount = tasks.count
    for task in tasks {
        AI.translate(task: task) { translation in
            write(translation, metadataKind: task.metadataKind, language: task.language)
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

func write(_ newValue: String, metadataKind: MetadataKind, language: Language) {
    let textToWrite: String = {
        if metadataKind == .keywords && newValue.count > 100 {
            print("🟡 trimming \(language.name) keywords")
            return String(newValue.prefix(100))
        } else {
            return newValue
        }
    }()
    let url = url(metadataKind: metadataKind, language: language)
    let data = textToWrite.data(using: .utf8)!
    try! data.write(to: url)
}

func originalMetadata(kind: MetadataKind, language: Language) -> String {
    let suffix = kind.toTranslate && language == .russian ? "_ru" : ""
    let url = URL(fileURLWithPath: projectDir + "/app_store/" + "\(kind.fileName)\(suffix).txt")
    return read(url: url)
}

func url(metadataKind: MetadataKind, language: Language) -> URL {
    return URL(fileURLWithPath: projectDir + "/fastlane/metadata/" + "\(language.metadataLocalizationKey)/\(metadataKind.fileName).txt")
}

