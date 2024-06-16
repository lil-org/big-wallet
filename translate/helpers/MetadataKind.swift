// ∅ 2024 lil org

import Foundation

enum MetadataKind: String, CaseIterable {
    case description
    case keywords
    case name
    case subtitle
    case promotionalText = "promotional_text"
    case releaseNotes = "release_notes"
    case marketingURL = "marketing_url"
    case privacyURL = "privacy_url"
    case supportURL = "support_url"
    
    var fileName: String {
        return rawValue
    }
    
    var toTranslate: Bool {
        switch self {
        case .description, .keywords, .name, .subtitle, .promotionalText, .releaseNotes:
            return true
        case .marketingURL, .privacyURL, .supportURL:
            return false
        }
    }
    
}
