// ∅ 2024 lil org

import Foundation

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
        case .norwegian:
            return "no"
        default:
            return rawValue
        }
    }
    
    var name: String {
        switch self {
        case .english:
            return "english"
        case .arabic:
            return "arabic"
        case .catalan:
            return "catalan"
        case .chinese:
            return "chinese (simplified)"
        case .croatian:
            return "croatian"
        case .czech:
            return "czech"
        case .danish:
            return "danish"
        case .dutch:
            return "dutch"
        case .finnish:
            return "finnish"
        case .french:
            return "french"
        case .german:
            return "german"
        case .greek:
            return "greek"
        case .hebrew:
            return "hebrew"
        case .hindi:
            return "hindi"
        case .hungarian:
            return "hungarian"
        case .indonesian:
            return "indonesian"
        case .italian:
            return "italian"
        case .japanese:
            return "japanese"
        case .korean:
            return "korean"
        case .malay:
            return "malay"
        case .norwegian:
            return "norwegian"
        case .polish:
            return "polish"
        case .portugeseBrazil:
            return "portugese (brazil)"
        case .portugese:
            return "portugese"
        case .romanian:
            return "romanian"
        case .russian:
            return "russian"
        case .slovak:
            return "slovak"
        case .spanish:
            return "spanish"
        case .spanishLatinAmerica:
            return "spanish (latin america)"
        case .swedish:
            return "swedish"
        case .thai:
            return "thai"
        case .turkish:
            return "turkish"
        case .ukrainian:
            return "ukrainian"
        case .vietnamese:
            return "vietnamese"
        }
    }
    
}
