//
//  CoAPTransport.swift
//  NDMAPI
//
//  Created by Roman on 20/12/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

public protocol CoAPClient: AnyObject {
    func send(_ message: CoAPMessage) throws
    func send(_ message: CoAPMessage, block2DownloadProgress: ((Data) -> Void)?) throws
    func set(transport: Coala.Transport, completion: @escaping () -> Void) throws

    /// Promoted to requirements in Phase 6 so a non-Coala transport can
    /// supply its own witnesses; the extension methods in
    /// CoAPClient+Observe.swift become the default implementations verbatim.
    func startObserving(url: URL, onUpdate: @escaping Coala.ResponseHandler)
    func stopObserving(url: URL, onStop: (() -> Void)?)
}

public protocol CoAPServer: AnyObject {
    func addResource(_ resource: CoAPResourceProtocol)
    func removeResources(forPath path: String)
}

public typealias CoAPTransport = CoAPClient & CoAPServer

extension Coala: CoAPTransport { }
