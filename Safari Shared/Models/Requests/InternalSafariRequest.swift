// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct InternalSafariRequest: Codable {
    let id: Int
    let subject: Subject
    
    enum Subject: String, Codable {
        case getResponse, didCompleteRequest, cancelRequest
    }
}
