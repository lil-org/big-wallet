import SPDiffable
import UIKit
import SparrowKit

extension SPDiffableTableDataSource.CellProvider {
    
    public static var chain: SPDiffableTableDataSource.CellProvider  {
        return SPDiffableTableDataSource.CellProvider() { (tableView, indexPath, item) -> UITableViewCell? in
            guard let item = item as? SPDiffableTableRowSubtitle else { return nil }
            let cell = tableView.dequeueReusableCell(withIdentifier: SPDiffableSubtitleTableViewCell.reuseIdentifier, for: indexPath) as! SPDiffableSubtitleTableViewCell
            cell.textLabel?.text = item.text
            cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .title3, weight: .semibold).rounded
            cell.detailTextLabel?.text = item.subtitle
            cell.detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .footnote, weight: .semibold).monospaced
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.imageView?.image = item.icon
            cell.accessoryType = item.accessoryType
            cell.selectionStyle = item.selectionStyle
            return cell
        }
    }
}
