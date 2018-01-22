//
//  DDLog+CoalaLogger.swift
//  Coala
//
//  Created by Roman on 02/12/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Coala

extension DDLog: CoalaLogger {

    public func log(_ message: String, level: LogLevel, asynchronous: Bool) {
        let flag: DDLogFlag
        switch level {
        case .debug:
            flag = .debug
        case .info:
            flag = .info
        case .warning:
            flag = .warning
        case .verbose:
            flag = .verbose
        case .error:
            flag = .error
        }
        _DDLogMessage(message,
                      level: defaultDebugLevel,
                      flag: flag,
                      context: 0,
                      file: #file,
                      function: #function,
                      line: #line,
                      tag: nil,
                      asynchronous: asynchronous,
                      ddlog: self)

    }

}
