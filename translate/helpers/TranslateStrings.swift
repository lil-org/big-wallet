// ∅ 2024 lil org

import Foundation

func translateAllStrings(_ model: AI.Model) {
    let strings = readStrings()
    processNextKey(model, oldStrings: strings, newStrings: strings)
    semaphore.wait()
}

func processNextKey(_ model: AI.Model, oldStrings: [String: Any], newStrings: [String: Any]) {
    guard let (key, dict) = oldStrings.first else {
        print("✅ strings all done")
        semaphore.signal()
        return
    }
    
    var oldStrings = oldStrings
    var newStrings = newStrings
    
    oldStrings.removeValue(forKey: key)
    
    processSpecificString(model, key: key, dict: dict as! [String: Any]) { result in
        newStrings[key] = result
        writeStrings(newStrings)
        processNextKey(model, oldStrings: oldStrings, newStrings: newStrings)
    }
}

func processSpecificString(_ model: AI.Model, key: String, dict: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    let hash = (dict["comment"] as? String) ?? ""
    let localizations = dict["localizations"] as! [String: Any]
    
    guard !isUtilityDoNotTouch(hash) else {
        if localizations.count == Language.allCases.count {
            completion(dict)
        } else {
            var filledDict = dict
            let engDict = localizations[Language.english.appLocalizationKey]
            var allLocalizationsDict = [String: Any]()
            for language in Language.allCases {
                allLocalizationsDict[language.appLocalizationKey] = engDict
            }
            filledDict["localizations"] = allLocalizationsDict
            completion(filledDict)
        }
        return
    }
    
    let english = read(language: .english, from: localizations)!
    let russian = read(language: .russian, from: localizations)!
    let newTargetHash = StringTask(model: model, language: .japanese, englishText: english, russianText: russian).hash
    let forceTranslateAll = hash != newTargetHash
    
    guard localizations.count < Language.allCases.count || forceTranslateAll else {
        completion(dict)
        return
    }
    
    var dict: [Language: String] = [
        .english: english,
        .russian: russian
    ]
    
    func addTranslation(language: Language, value: String) {
        dict[language] = value
        if dict.count == Language.allCases.count {
            let formatted = formatLocalizationsDict(dict)
            let output: [String : Any] = ["comment": newTargetHash, "localizations": formatted]
            completion(output)
        }
    }
    
    for language in Language.allCases where language != .english && language != .russian {
        if let currentValue = read(language: language, from: localizations), !forceTranslateAll {
            queue.async {
                addTranslation(language: language, value: currentValue)
            }
        } else {
            translate(model, to: language, english: english, russian: russian) { result in
                addTranslation(language: language, value: result)
            }
        }
    }
}

func translate(_ model: AI.Model, to: Language, english: String, russian: String, completion: @escaping (String) -> Void) {
    let task = StringTask(model: model, language: to, englishText: english, russianText: russian)
    AI.translate(task: task) { result in
        completion(result)
    }
}

func formatLocalizationsDict(_ input: [Language: String]) -> [String: Any] {
    var output = [String: Any]()
    
    for (key, value) in input {
        output[key.appLocalizationKey] = ["stringUnit": ["state" : "translated", "value": value]]
    }
    
    return output
}

func isUtilityDoNotTouch(_ comment: String) -> Bool {
    return comment == "IS_UTILITY_STRING_DO_NOT_TRANSLATE"
}

func read(language: Language, from localizations: [String: Any]) -> String? {
    let unit = (localizations[language.appLocalizationKey] as? [String: Any])?["stringUnit"] as? [String: String]
    let value = unit?["value"]
    return value
}

func writeStrings(_ newStrings: [String: Any]) {
    let newDict: [String: Any] = ["sourceLanguage": "en", "strings": newStrings, "version" : "1.0"]
    let data = try! JSONSerialization.data(withJSONObject: newDict, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: stringsURL)
}

func readStrings() -> [String: Any] {
    let data = try! Data(contentsOf: stringsURL)
    let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let strings = json["strings"] as! [String: Any]
    return strings
}

private let stringsURL = URL(fileURLWithPath: projectDir + "/Shared/Supporting Files/Localizable.xcstrings")

