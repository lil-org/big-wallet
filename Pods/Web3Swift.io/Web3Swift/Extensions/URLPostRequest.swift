//
// This source file is part of the Web3Swift.io open source project
// Copyright 2018 The Web3Swift Authors
// Licensed under Apache License v2.0
//
// URLPostRequest.swift
//
// Created by Timofey Solonin on 10/05/2018
//

import Foundation

//FIXME: Init should throw since URLRequest is actually HTTPURLRequest
internal final class URLPostRequest {

    private let url: URL
    private let body: Data
    private let headers: Dictionary<String, String>
    internal init(url: URL, body: Data, headers: Dictionary<String, String>) {
        self.url = url
        self.body = body
        self.headers = headers
    }

    internal func toURLRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        headers.forEach {
            request.addValue($0.value, forHTTPHeaderField: $0.key)
        }
        return request
    }

}
