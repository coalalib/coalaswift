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

    // swiftlint:disable function_parameter_count
    /**
     Coala produced a log message.

     - parameter message: The message to be logged.
     - parameter level: Level of log message importance.
     - parameter asynchronous: Describes how time-critical log message is.
     If set to `true`, logging can be delayed until later.
     If set to `false`, message should be logged immediately.
     */
    func log(_ message: String, level: LogLevel, asynchronous: Bool)

    /**
     Coala produced a log message with structured context and its original caller location.

     - parameter message: The message to be logged.
     - parameter level: Level of log message importance.
     - parameter asynchronous: Describes how time-critical log message is.
     - parameter context: Event-specific fields, already reduced to JSON-compatible values
     by `LogContext.normalize`.
     - parameter file: File containing the original logging call.
     - parameter function: Function containing the original logging call.
     - parameter line: Line containing the original logging call.
     */
    func log(_ message: String, level: LogLevel, asynchronous: Bool,
             context: [String: Any], file: String, function: String, line: UInt)
}

public extension CoalaLogger {

    func log(_ message: String, level: LogLevel, asynchronous: Bool,
             context: [String: Any], file: String, function: String, line: UInt) {
        log(message, level: level, asynchronous: asynchronous)
    }
}

/// Forwards one record to `Coala.logger` with a JSON-safe copy of `context`. Prefer the
/// level-specific functions below; this is for callers whose level is data.
public func Log(_ message: String, level: LogLevel, asynchronous: Bool = true,
                context: [String: Any] = [:], file: String = #file,
                function: String = #function, line: UInt = #line) {
    Coala.logger?.log(
        message,
        level: level,
        asynchronous: asynchronous,
        context: LogContext.normalize(context),
        file: file,
        function: function,
        line: line
    )
}
// swiftlint:enable function_parameter_count

public func LogDebug(_ message: String, asynchronous: Bool = true,
                     context: [String: Any] = [:], file: String = #file,
                     function: String = #function, line: UInt = #line) {
    Log(message, level: .debug, asynchronous: asynchronous,
        context: context, file: file, function: function, line: line)
}

public func LogInfo(_ message: String, asynchronous: Bool = true,
                    context: [String: Any] = [:], file: String = #file,
                    function: String = #function, line: UInt = #line) {
    Log(message, level: .info, asynchronous: asynchronous,
        context: context, file: file, function: function, line: line)
}

public func LogWarn(_ message: String, asynchronous: Bool = true,
                    context: [String: Any] = [:], file: String = #file,
                    function: String = #function, line: UInt = #line) {
    Log(message, level: .warning, asynchronous: asynchronous,
        context: context, file: file, function: function, line: line)
}

public func LogVerbose(_ message: String, asynchronous: Bool = true,
                       context: [String: Any] = [:], file: String = #file,
                       function: String = #function, line: UInt = #line) {
    Log(message, level: .verbose, asynchronous: asynchronous,
        context: context, file: file, function: function, line: line)
}

public func LogError(_ message: String, asynchronous: Bool = true,
                     context: [String: Any] = [:], file: String = #file,
                     function: String = #function, line: UInt = #line) {
    Log(message, level: .error, asynchronous: asynchronous,
        context: context, file: file, function: function, line: line)
}

class DefaultLogger: CoalaLogger {

    var minLogLevel: LogLevel = .warning
    let dateFormatter = DateFormatter()

    init() {
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ message: String, level: LogLevel, asynchronous: Bool) {
        write(message, level: level, contextDescription: "")
    }

    // swiftlint:disable function_parameter_count
    func log(_ message: String, level: LogLevel, asynchronous: Bool,
             context: [String: Any], file: String, function: String, line: UInt) {
        let contextDescription: String
        if !context.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: context, options: []),
           let json = String(data: data, encoding: .utf8) {
            contextDescription = " \(json)"
        } else {
            contextDescription = ""
        }
        write(message, level: level, contextDescription: contextDescription)
    }
    // swiftlint:enable function_parameter_count

    private func write(_ message: String, level: LogLevel, contextDescription: String) {
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
        print("\(dateString) \(emoji) \(message)\(contextDescription)")
    }
}
