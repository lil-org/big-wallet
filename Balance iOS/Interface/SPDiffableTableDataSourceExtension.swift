import UIKit
import SPDiffable

extension SPDiffableTableDataSource.CellProvider {
    
    public static var rowDetailMultiLines: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let item = item as? SPDiffableTableRow else { return nil }
            let cell = tableView.dequeueReusableCell(withIdentifier: SPDiffableTableViewCell.reuseIdentifier, for: indexPath) as! SPDiffableTableViewCell
            cell.textLabel?.text = item.text
            cell.textLabel?.numberOfLines = .zero
            cell.detailTextLabel?.text = item.detail
            cell.detailTextLabel?.numberOfLines = .zero
            cell.imageView?.image = item.icon
            cell.accessoryType = item.accessoryType
            cell.selectionStyle = item.selectionStyle
            return cell
        }
    }
}
