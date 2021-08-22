//
//  SimpleCollectionViewController.swift
//  SwiftStoreExample
//
//  Created by Hemanta Sapkota on 3/06/2015.
//  Copyright (c) 2015 Hemanta Sapkota. All rights reserved.
//

import Foundation
import UIKit

class SimpleCollectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    var sectionTitles = ["Common Names", "Popular Places"]
    
    override func viewDidLoad() {
        
        let tableView = UITableView()
        tableView.dataSource = self
        tableView.delegate = self
        
        tableView.register(TableViewCell.self, forCellReuseIdentifier: "Cell")
        
        view = tableView
    }
    
}

extension SimpleCollectionViewController {
    
    @objc(numberOfSectionsInTableView:) func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 10
    }
    
    @objc(tableView:cellForRowAtIndexPath:) func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell") as! TableViewCell
        cell.textLabel!.text = "Hello"
        return cell
    }
    
}

extension SimpleCollectionViewController {
    
    class TableViewCell : UITableViewCell {
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
        }

        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
    }
    
}
