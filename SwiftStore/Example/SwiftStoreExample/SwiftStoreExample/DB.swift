//
//  DB.swift
//  SwiftStoreExample
//
//  Created by Hemanta Sapkota on 12/05/2015.
//  Copyright (c) 2015 Hemanta Sapkota. All rights reserved.
//

import Foundation
import SwiftStore

class DB : SwiftStore {
  
  class var store:DB {
    struct Singleton {
      static let instance = DB(storeName: "db")
    }
    return Singleton.instance
  }
  
}