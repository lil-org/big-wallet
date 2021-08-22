//
//  ExampleViewController.swift
//  SwiftStoreExample
//
//  Created by Hemanta Sapkota on 31/05/2015.
//  Copyright (c) 2015 Hemanta Sapkota. All rights reserved.
//

import Foundation
import UIKit
import SnapKit

class ExampleViewController : UIViewController {
    
    override func viewDidLoad() {
        title = "Swift Store Demo"
        
        let exampleView = ExampleView()
        
        exampleView.viewPusher = { viewController in
            self.navigationController?.pushViewController(viewController, animated: true)
        }
        
        view = exampleView
    }
}

class ExampleView : UIView, UITableViewDataSource, UITableViewDelegate {
    
    /* Items */
    var items = ["Saving Key / Value Pairs" ]
    
    /* Table View */
    var tableView: UITableView!
    
    var viewPusher: ( (UIViewController) -> Void)!
    
    init() {
        super.init(frame: UIScreen.main.bounds)
        
        tableView = UITableView()
        tableView.dataSource = self
        tableView.delegate = self
        addSubview(tableView)
        tableView.snp_makeConstraints { (make) -> Void in
            make.top.equalTo(0)
            make.left.equalTo(0)
            make.width.equalTo(self.snp_width)
            make.height.equalTo(self.snp_height)
        }
        
        tableView.register(ExampleViewCell.self, forCellReuseIdentifier: "ExampleViewCell")
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ExampleViewCell") as! ExampleViewCell
        
        cell.textLabel?.text = items[(indexPath as NSIndexPath).item]
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        let item = (indexPath as NSIndexPath).item
        
        if item == 0 {
            viewPusher(SimpleKeyValueViewController())
        } else if item == 1 {
//            viewPusher(SimpleCollectionViewController())
        }
    }
}

class ExampleViewCell : UITableViewCell {
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}
