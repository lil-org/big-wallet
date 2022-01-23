// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

extension UITableView {
    
    func registerReusableCell<Cell: UITableViewCell>(type: Cell.Type) {
        let cellName = String(describing: type)
        register(UINib(nibName: cellName, bundle: nil), forCellReuseIdentifier: cellName)
    }
    
    func registerReusableHeaderFooter<Header: UITableViewHeaderFooterView>(type: Header.Type) {
        let headerFooterName = String(describing: type)
        register(UINib(nibName: headerFooterName, bundle: nil), forHeaderFooterViewReuseIdentifier: headerFooterName)
    }
    
    func dequeueReusableCellOfType<Cell: UITableViewCell>(_ type: Cell.Type, for indexPath: IndexPath) -> Cell {
        return dequeueReusableCell(withIdentifier: String(describing: type), for: indexPath) as! Cell
    }
    
    func dequeueReusableHeaderFooterOfType<Header: UITableViewHeaderFooterView>(_ type: Header.Type) -> Header {
        return dequeueReusableHeaderFooterView(withIdentifier: String(describing: type)) as! Header
    }
    
    func scrollTableViewToTop(animated: Bool) {
        if numberOfSections > 0, numberOfRows(inSection: 0) > 0 {
            scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: animated)
        }
    }
    
}
