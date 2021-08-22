//
//  ViewController.swift
//  SwiftStoreExample
//
//  Created by Hemanta Sapkota on 12/05/2015.
//  Copyright (c) 2015 Hemanta Sapkota. All rights reserved.
//
import UIKit

class SimpleKeyValueViewController: UIViewController {

  override func viewDidLoad() {
    super.viewDidLoad()
    
    title = "Swift Store Demo"
    
    view = SimpleKeyValueView()
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
  }
}

class SimpleKeyValueView : UIView {
    
    init() {
        super.init(frame: UIScreen.main.bounds)
        
        backgroundColor = UIColor.white
        
        var keys = ["Name", "Address", "Phone", "Email"]
        
        var lastRow: SimpleRowView? = nil
        var index = 1
        
        for key in keys {
            let row = SimpleRowView(rowNumber: index, key: key)
            
            let value = DB.store[key]!
            if !value.isEmpty {
                row.valueText.text = value
            }
            
            row.onSave = { (key, value) in
                DB.store[key] = value
            }
            
            row.onDelete = { key in
                DB.store.delete(key: key)
            }
            
            addSubview(row)
            row.snp_makeConstraints { (make) -> Void in
                if lastRow == nil {
                    make.top.equalTo(70)
                } else {
                    make.top.greaterThanOrEqualTo(lastRow!.snp_bottom).offset(5)
                }
                
                make.left.equalTo(0)
                make.width.equalTo(self.snp_width)
                make.height.equalTo(110)
                
                lastRow = row
                index = index + 1
            }
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
