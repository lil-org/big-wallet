import UIKit
import SPDiffable
import NativeUIKit

extension SPDiffableTableDataSource.CellProvider {
    
    public static var buttonMultiLines: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let item = item as? NativeDiffableLeftButton else { return nil }
            let cell = tableView.dequeueReusableCell(withClass: NativeLeftButtonTableViewCell.self, for: indexPath)
            cell.textLabel?.text = item.text
            cell.textLabel?.textColor = item.textColor
            cell.textLabel?.numberOfLines = .zero
            cell.detailTextLabel?.text = item.detail
            cell.detailTextLabel?.textColor = item.detailColor
            cell.imageView?.image = item.icon
            cell.accessoryType = item.accessoryType
            cell.higlightStyle = .content
            return cell
        }
    }
    
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
