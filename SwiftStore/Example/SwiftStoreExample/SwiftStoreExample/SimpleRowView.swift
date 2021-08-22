//
//  RowView.swift
//  SwiftStoreExample
//
//  Created by Hemanta Sapkota on 31/05/2015.
//  Copyright (c) 2015 Hemanta Sapkota. All rights reserved.
//

import Foundation
import UIKit

/* Simple Row View */
class SimpleRowView : UIView {
    
    /* Label */
    var label: UILabel!
    
    /* Key Text */
    var keyText: UITextField!
    
    /* Value Text */
    var valueText: UITextField!
    
    /* Save Button */
    var saveBtn: UIButton!
    
    /* Delete */
    var deleteBtn: UIButton!
    
    /* Handler */
    var onSave: ( (String, String) -> Void)?
    
    /* Handler */
    var onDelete: ( (String) -> Void)?
    
    init(rowNumber: Int, key: String) {
        super.init(frame: UIScreen.main.bounds)
        
        label = UILabel()
        label.text = "\(rowNumber)"
        label.textColor = UIColor(rgba: "#2c3e50")
        addSubview(label)
        label.snp_makeConstraints { (make) -> Void in
            make.top.equalTo(5)
            make.left.equalTo(5)
        }
        
        keyText = UITextField()
        keyText.layer.borderWidth = 0.5
        keyText.layer.borderColor = UIColor(rgba: "#bdc3c7").cgColor
        keyText.placeholder = "Key"
        keyText.text = "\(key)"
        keyText.isEnabled = false
        addSubview(keyText)
        keyText.snp_makeConstraints { (make) -> Void in
            make.top.greaterThanOrEqualTo(5)
            make.left.equalTo(label.snp_right).offset(10)
            make.width.equalTo(self.snp_width).offset(-60)
            make.height.equalTo(30)
        }
        
        valueText = UITextField()
        valueText.placeholder = "Value"
        valueText.layer.borderWidth = 0.5
        valueText.layer.borderColor = UIColor(rgba: "#bdc3c7").cgColor
        addSubview(valueText)
        valueText.snp_makeConstraints { (make) -> Void in
            make.top.greaterThanOrEqualTo(keyText.snp_bottom).offset(5)
            make.left.equalTo(label.snp_right).offset(10)
            make.width.equalTo(self.snp_width).offset(-60)
            make.height.equalTo(30)
        }
        
        saveBtn = UIButton(type: UIButton.ButtonType.system)
        saveBtn.setTitleColor(UIColor.white, for: UIControl.State())
        saveBtn.setTitle("Save", for: UIControl.State())
        saveBtn.backgroundColor = UIColor(rgba: "#27ae60")
        addSubview(saveBtn)
        saveBtn.snp_makeConstraints { (make) -> Void in
            make.top.greaterThanOrEqualTo(valueText.snp_bottom).offset(5)
            make.left.equalTo(valueText.snp_left)
            make.width.equalTo(self.snp_width).dividedBy(3)
        }
        
        deleteBtn = UIButton(type: UIButton.ButtonType.system)
        deleteBtn.setTitleColor(UIColor.white, for: UIControl.State())
        deleteBtn.setTitle("Delete", for: UIControl.State())
        deleteBtn.backgroundColor = UIColor(rgba: "#e74c3c")
        addSubview(deleteBtn)
        deleteBtn.snp_makeConstraints { (make) -> Void in
            make.top.greaterThanOrEqualTo(valueText.snp_bottom).offset(5)
            make.right.equalTo(valueText.snp_right)
            make.width.equalTo(self.snp_width).dividedBy(3)
        }
        
        let sep = UILabel()
        sep.backgroundColor = UIColor(rgba: "#bdc3c7")
        addSubview(sep)
        sep.snp_makeConstraints { (make) -> Void in
            make.height.equalTo(0.5)
            make.bottom.equalTo(self.snp_bottom)
            make.width.equalTo(self.snp_width)
        }
        
        saveBtn.addTarget(self, action: #selector(SimpleRowView.handleSave), for: UIControl.Event.touchUpInside)
        deleteBtn.addTarget(self, action: #selector(SimpleRowView.handleDelete), for: UIControl.Event.touchUpInside)
    }
    
    @objc func handleSave() {
        if let executeSave = onSave {
            let key = keyText.text!.trimmingCharacters(in: CharacterSet.whitespaces)
            let value = valueText.text!.trimmingCharacters(in: CharacterSet.whitespaces)
            executeSave(key, value)
        }
    }
    
    @objc func handleDelete() {
        valueText.text = ""
        if let executeDelete = onDelete {
            let key = keyText.text!.trimmingCharacters(in: CharacterSet.whitespaces)
            executeDelete(key)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
    
