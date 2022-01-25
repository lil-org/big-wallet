import UIKit
import SparrowKit
import SPDiffable

class SidebarController: SPDiffableSideBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        configureDiffable(sections: content, cellProviders: SPDiffableCollectionDataSource.CellProvider.sideBar, headerAsFirstCell: true)
        selectFirstBar()
        navigationItem.title = Texts.App.name_short
        
        if UIDevice.current.isMac {
            navigationController?.setNavigationBarHidden(true, animated: false)
        }
    }
    
    @objc func updateContent() {
        diffableDataSource?.set(content, animated: true)
    }
    
    var content: [SPDiffableSection] {
        return Navigation.sideBars.map { (barSection) -> SPDiffableSection in
            
            let diffableSection = SPDiffableSection(
                id: barSection.id,
                items: []
            )
            
            if let sectionTitle = barSection.title {
                diffableSection.header = SPDiffableSideBarHeader(text: sectionTitle, accessories: [.outlineDisclosure()])
            }
            
            for bar in barSection.rows {
                let bar = SPDiffableSideBarItem(id: bar.id, title: bar.title, image: bar.image) { [weak self] _, _ in
                    guard let self = self else { return }
                    self.splitViewController?.setViewController(bar.getController(), for: .secondary)
                }
                diffableSection.items.append(bar)
            }
            
            return diffableSection
        }
    }
    
    func selectFirstBar() {
        collectionView.selectItem(at: .init(item: .zero, section: .zero), animated: false, scrollPosition: .top)
    }
}
