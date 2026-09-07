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
        log(message, level: level, asynchronous: asynchronous,
            context: [:], file: #file, function: #function, line: #line)
    }

    // swiftlint:disable:next function_parameter_count
    public func log(_ message: String, level: LogLevel, asynchronous: Bool,
                    context: [String: Any], file: String, function: String, line: UInt) {
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

        let logLevel = defaultDebugLevel
        guard logLevel.rawValue & flag.rawValue != 0,
              dynamicLogLevel.rawValue & flag.rawValue != 0 else {
            return
        }

        let logMessage = DDLogMessage(format: message,
                                      formatted: message,
                                      level: logLevel,
                                      flag: flag,
                                      context: 0,
                                      file: file,
                                      function: function,
                                      line: line,
                                      tag: context,
                                      options: [.copyFile, .copyFunction],
                                      timestamp: nil)
        log(asynchronous: asynchronous, message: logMessage)
    }

}
