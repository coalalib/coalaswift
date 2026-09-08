//
//  LogContext.swift
//  Coala
//

import Foundation

/// Produces value snapshots that are safe to pass to JSON-backed loggers.
public enum LogContext {

    private static let maximumDepth = 16

    /// Copies `context`, keeping only JSON-compatible values: strings, finite numbers,
    /// booleans, `NSNull`, and nested dictionaries/arrays of those. Invalid values are dropped
    /// one by one, so their valid siblings survive. The result is a fresh value snapshot.
    public static func normalize(_ context: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in context {
            if let value = sanitize(value, depth: 0) {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    /// `extra` plus one `reason` for `error` (unless `extra` already has one): the case name
    /// of a Swift error, or `"<domain> <code>"` for a Foundation/Cocoa error such as
    /// `NSURLErrorDomain -1001`. Never the description. A `nil` error yields just `extra`.
    public static func error(_ error: Error?, _ extra: [String: Any] = [:]) -> [String: Any] {
        var context = extra
        if let error = error, context["reason"] == nil {
            context["reason"] = reason(error)
        }
        return context
    }

    /// One short `reason` for an error: a Swift error's case name in `snake_case` (any
    /// payload stripped), or `"<domain> <code>"` for a Foundation/Cocoa error.
    public static func reason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain != String(reflecting: Swift.type(of: error)) {
            return "\(nsError.domain) \(nsError.code)"
        }
        var result = ""
        for character in String(describing: error).prefix(while: { $0 != "(" }) {
            if character.isUppercase {
                if !result.isEmpty { result.append("_") }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func sanitize(_ value: Any, depth: Int) -> Any? {
        if let string = value as? String {
            return string
        }
        if value is NSNull {
            return NSNull()
        }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number : nil
        }

        guard depth < maximumDepth else { return nil }

        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                guard let stringKey = key as? String,
                      let normalizedValue = sanitize(nestedValue, depth: depth + 1) else {
                    continue
                }
                result[stringKey] = normalizedValue
            }
            return result
        }
        if let array = value as? NSArray {
            return array.compactMap { sanitize($0, depth: depth + 1) }
        }
        return nil
    }
}
