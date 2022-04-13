//
//  CoAPTransport.swift
//  NDMAPI
//
//  Created by Roman on 20/12/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

public protocol CoAPClient: AnyObject {
    func send(_ message: CoAPMessage) throws
    func send(_ message: CoAPMessage, block2DownloadProgress: ((Data) -> Void)?) throws
    func startTcpProxying(host: String) throws
}

public protocol CoAPServer: AnyObject {
    func addResource(_ resource: CoAPResourceProtocol)
    func removeResources(forPath path: String)
}

public typealias CoAPTransport = CoAPClient & CoAPServer

extension Coala: CoAPTransport { }
