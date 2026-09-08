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
    /// `completion` is called exactly once with `nil` on success, or with the
    /// reason the transport could not be established. Receiving that error (or the
    /// throw) makes the caller the owner of reporting it; the client logs it at DEBUG.
    func set(transport: Coala.Transport, completion: @escaping (Error?) -> Void) throws
}

public protocol CoAPServer: AnyObject {
    func addResource(_ resource: CoAPResourceProtocol)
    func removeResources(forPath path: String)
}

public typealias CoAPTransport = CoAPClient & CoAPServer

extension Coala: CoAPTransport { }
