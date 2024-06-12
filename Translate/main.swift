// ∅ 2024 lil org

import Foundation

enum MetadataKind: String {
    case description
    case keywords
    case name
    case subtitle
    case promotionalText = "promotional_text"
    case releaseNotes = "release_notes"
}

enum Language: String, CaseIterable {
    
    case english = "en"
    case arabic = "ar"
    case catalan = "ca"
    case chinese = "zh-Hans"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case malay = "ms"
    case norwegian = "nb"
    case polish = "pl"
    case portugeseBrazil = "pt-BR"
    case portugese = "pt-PT"
    case romanian = "ro"
    case russian = "ru"
    case slovak = "sk"
    case spanish = "es"
    case spanishLatinAmerica = "es-419"
    case swedish = "sv"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case vietnamese = "vi"
    
    var appLocalizationKey: String {
        return rawValue
    }
    
    var metadataLocalizationKey: String {
        switch self {
        case .arabic:
            return "ar-SA"
        case .english:
            return "en-US"
        case .dutch:
            return "nl-NL"
        case .french:
            return "fr-FR"
        case .german:
            return "de-DE"
        case .spanish:
            return "es-ES"
        case .spanishLatinAmerica:
            return "es-MX"
        default:
            return rawValue
        }
    }
    
}

translateAppStoreMetadata()

func translateAppStoreMetadata() {
    print("yo")
    // TODO: go trough all locales
    // TODO: use en and ru versions as a reference
    // TODO: check if there were changes since the last translation run
}
