// ∅ 2026 lil org

import UIKit

extension UITableView {
    
    func registerReusableCell<Cell: UITableViewCell>(type: Cell.Type) {
        let cellName = String(describing: type)
        register(type, forCellReuseIdentifier: cellName)
    }
    
    func registerReusableHeaderFooter<Header: UITableViewHeaderFooterView>(type: Header.Type) {
        let headerFooterName = String(describing: type)
        register(type, forHeaderFooterViewReuseIdentifier: headerFooterName)
    }
    
    func dequeueReusableCellOfType<Cell: UITableViewCell>(_ type: Cell.Type, for indexPath: IndexPath) -> Cell {
        return dequeueReusableCell(withIdentifier: String(describing: type), for: indexPath) as! Cell
    }
    
    func dequeueReusableHeaderFooterOfType<Header: UITableViewHeaderFooterView>(_ type: Header.Type) -> Header {
        return dequeueReusableHeaderFooterView(withIdentifier: String(describing: type)) as! Header
    }
    
}
