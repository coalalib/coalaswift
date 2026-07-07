//
//  CoAPThreadLock.swift
//  Coala
//
//  Created by Pavel Shatalov on 26/03/2019.
//  Copyright © 2019 NDM Systems. All rights reserved.
//

final public class Synchronized<T> {
  /// Private value. Use `public` `value` computed property (or `reader` and `writer` methods)
  /// for safe, thread-safe access to this underlying value.
  private var _value: T
  /// A plain mutex guards every access. A dispatch queue was avoided on
  /// purpose: `queue.sync` blocks the calling thread, which deadlocks when
  /// invoked from Swift Testing's cooperative thread pool, and the old async
  /// barrier setter made writes visible only later (forcing tests to poll).
  /// A lock keeps reads and writes synchronous and immediately visible, with
  /// no dependency on `Bundle.main.bundleIdentifier`.
  private let lock = NSLock()

  /// Create `Synchronized` object
  ///
  /// - Parameter value: The initial value to be synchronized.
  public init(value: T) {
    _value = value
  }

  /// A threadsafe variable to set and get the underlying object
  public var value: T {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _value
    }
    set {
      lock.lock()
      _value = newValue
      lock.unlock()
    }
  }

  /// A "reader" method to allow thread-safe, read-only access to the underlying object.
  ///
  /// - Warning: If the underlying object is a reference type, you are responsible for making sure you
  ///            do not mutating anything. If you stick with value types (`struct` or primitive types),
  ///            this will be enforced for you.
  public func reader<U>(_ block: (T) -> U) -> U {
    lock.lock()
    defer { lock.unlock() }
    return block(_value)
  }

  /// A "writer" method to allow thread-safe write to the underlying object
  public func writer(_ block: (inout T) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    block(&_value)
  }

  /// Atomic read-modify-write. The entire `block` runs under the lock, so
  /// compound mutations (`dict[key] = x`, `dict[key]?.field += 1`,
  /// `dict.removeValue(forKey:)`) are race-free, unlike `value[...] = ...`
  /// which is a non-atomic get-then-set.
  @discardableResult
  public func mutate<R>(_ block: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return block(&_value)
  }
}
