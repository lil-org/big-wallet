import UIKit

struct BarSectionModel {
    
    let id: String
    let title: String?
    let rows: [BarRowModel]
    
    init(id: String, title: String?, rows: [BarRowModel]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
    
    enum Item: String, CaseIterable {
        
        case main
        
        var id: String { return rawValue + "_section" }
    }
    
    init(_ item: Item, items: [BarRowModel]) {
        switch item {
        case .main:
            self.init(id: item.id, title: nil, rows: items)
        }
    }
}
