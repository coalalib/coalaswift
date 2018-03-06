//
//  Logging.swift
//  Coala
//
//  Created by Roman on 30/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

// swiftlint:disable identifier_name

import Foundation

/// Level of log message importance.
public enum LogLevel: UInt {
    case verbose, debug, info, warning, error
}

/// Implement this protocol to be able to receive log messages from Coala.
public protocol CoalaLogger {

    /**
     Coala produced a log message.

     - parameter message: The message to be logged.
     - parameter level: Level of log message importance.
     - parameter asynchronous: Describes how time-critical log message is.
     If set to `true`, logging can be delayed until later.
     If set to `false`, message should be logged immediately.
     */
    func log(_ message: String, level: LogLevel, asynchronous: Bool)
}

private func Log(_ message: String, level: LogLevel, asynchronous: Bool) {
    Coala.logger?.log(message, level: level, asynchronous: asynchronous)
}

func LogDebug(_ message: String, asynchronous: Bool = true) {
    Log(message, level: .debug, asynchronous: asynchronous)
}

func LogInfo(_ message: String, asynchronous: Bool = true) {
    Log(message, level: .info, asynchronous: asynchronous)
}

func LogWarn(_ message: String, asynchronous: Bool = true) {
    Log(message, level: .warning, asynchronous: asynchronous)
}

func LogVerbose(_ message: String, asynchronous: Bool = true) {
    Log(message, level: .verbose, asynchronous: asynchronous)
}

func LogError(_ message: String, asynchronous: Bool = true) {
    Log(message, level: .error, asynchronous: asynchronous)
}

class DefaultLogger: CoalaLogger {

    var minLogLevel: LogLevel = .warning
    let dateFormatter = DateFormatter()

    init() {
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ message: String, level: LogLevel, asynchronous: Bool) {
        guard level.rawValue >= minLogLevel.rawValue else { return }
        let dateString = dateFormatter.string(from: Date())
        let emoji: Character
        switch level {
        case .verbose:
            emoji = "💜"
        case .debug:
            emoji = "💚"
        case .info:
            emoji = "💙"
        case .warning:
            emoji = "💛"
        case .error:
            emoji = "❤️"
        }
        print("\(dateString) \(emoji) \(message)")
    }
}
