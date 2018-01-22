# Coala

Coala is an iOS library for secure communication over the [Constrained Application Protocol (CoAP)](http://coap.technology).

### Overview
* [Getting started](#getting-started)
* [Usage](#usage)
  + [Communication](#communication)
  + [Security](#security)
  + [Logging](#logging)
  + [Observer](#observer)

### Documentation

* [API Reference](https://ndmsystems.github.io/Coala-Swift/)

## Getting started

Coala supports iOS 9.0+.

To add Coala to your application:

 1. Add the Coala repository as a
    [submodule](https://git-scm.com/book/en/v2/Git-Tools-Submodules) of your
    application’s repository.
 1. Drag and drop `Coala.xcodeproj` into your application’s Xcode project or
    workspace.
 1. On the “General” tab of your application target’s settings, add
    `Coala.framework` and `Curve25519.framework` to the “Embedded Binaries” section.

## Usage

To use Coala you should create an instance of `Coala` class. Typically you will need just one instance and store it in a global variable. Note, that all messages you send in a communication session should be sent using this single instance.

```swift
let coala = Coala()
```

Do not try to use multiple `Coala` instances unless you have some reason for it (in this case you will have to associate a different port for every instance).

### Communication

Coala is designed to be used in P2P environments, and it is meant to be used both as a CoAP client and a CoAP server simultaneously.

When you want to act as a client you need to create a `CoAPMessage` struct and pass it to `Coala.send()` method. You may also want to set `onResponse` block that will be called after receiving a response to your message.

```swift
let url = URL(string: "coap://\(serverAddress)/client/get")
let message = CoAPMessage(type: .confirmable, method: .get, url: url)
message.onResponse = { response in
  // ...
}
try? coala.send(message)
```

In case you are exposing any data as a server, you should create CoAPResource instance and add it `Coala` using `addResource()`

```swift
let resource = CoAPResource(method: .get, path: "/msg") { query, payload in
    return (.content, "Hello from Coala server!")
}
coala.addResource(resource)
// After resource is no longer present you should remove it
coala.removeResource(forPath: "/msg")
```

### Security

To enable security you should just use `coaps` URL scheme instead of `coap`. Handshake sequence and e2e encryption are performed by Coala library automatically.


```swift
let nonSecureUrl = URL(string: "coap://\(serverAddress)/client/get")
let secureUrl = URL(string: "coaps://\(serverAddress)/client/get")
```

### Logging

You can use your any logger with Coala. To do that you will have to implement an extension for your logger that conforms to `CoalaLogger` protocol and set it to `Coala.logger` property.

In case you are using [`CocoaLumberjack`](https://github.com/CocoaLumberjack/CocoaLumberjack) you may want to use `DDLog+CoalaLogger` extension from `/Extensions`.

```swift
DDLog.add(DDASLLogger())
DDLog.add(DDTTYLogger())
Coala.logger = DDLog.sharedInstance
```

### Observer

Coala also supports [observer protocol](https://tools.ietf.org/html/rfc7641).

To subscribe to an observable resource over CoAP, call `startObserving(:)` method. To unsubscribe call `stopObserving()`.

```swift
let url = URL(string: "coap://\(serverAddress)/client/get")
coala.startObserving(url: url) { notification in
  // This block will be executed every time the resource changes
}

// When done observing
coala.stopObserving(url: url)
```

To expose a resource that can be observed, use `ObservableResource` instead of `CoAPResource`. You also must call `notifyObservers()` method every time the observed state changes. This will send notifications to all clients observing the resource.

```swift
let resource = ObservableResource(path: "/changing") { message in
    return (.content, nil)
}
coala.addResource(resource)

// When the observed state changes
resource.notifyObservers()
```
