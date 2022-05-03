//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// URLSession.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

fileprivate class UnknownURLSessionError: DescribedError {

    public var description: String {
        return "Unknown URLSession error"
    }

}

extension URLSession {

    public func data(from request: URLRequest) throws -> Data {
        var data: Data? = nil
        var error: Error? = nil
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(
            with: request,
            completionHandler: { (taskData: Data?, response: URLResponse?, taskError: Error?) in
                if let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode) {
                    data = taskData
                }
                error = taskError
                semaphore.signal()
            }).resume()
        semaphore.wait()
        if let error = error {
            throw error
        } else if let data = data  {
            return data
        }
        throw UnknownURLSessionError()
    }

}
