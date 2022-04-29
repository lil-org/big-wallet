//
// This source file is part of the Web3Swift.io open source project
// Copyright 2019 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// CachedProcedure.swift
//
// Created by Vadim Koleoshkin on 20/05/2019
//

import Foundation
import SwiftyJSON

/** Permanently cached procedure */
public final class CachedProcedure: RemoteProcedure {
    
    private let stickyValue: StickyComputation<JSON>
    
    /**
     Ctor
     
     - parameters:
        - origin: procedure to cache
     */
    public init(origin: RemoteProcedure) {
        self.stickyValue = StickyComputation{
            try origin.call()
        }
    }

    /**
     - returns:
     Cashed `JSON` from the procedure
     
     - throws:
     `DescribedError` if something went wrong
     */
    public func call() throws -> JSON {
        return try stickyValue.result()
    }
    
    
    
}
