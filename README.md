# Coala Swift

Swift implementation of Coala on top of CoAP messages. The framework is built
for iOS applications and provides a peer-to-peer CoAP client/server stack over
UDP or Coala TCP frames.

Coala Swift includes the main Coala protocol surface:

- UDP client/server API over CoAP datagram encoding.
- Coala TCP frame transport.
- Resources with `GET`, `POST`, `PUT`, and `DELETE` handlers.
- Response callbacks, retransmit pool, and delivery statistics.
- Observe registrations and notifications.
- Multicast discovery on `224.0.0.187:5683/info`.
- Proxy options.
- Block1/Block2 and selective-repeat ARQ for large payloads.
- `coaps` handshake/encryption with Curve25519, HKDF-SHA256, and AES-GCM using
  Coala's 12-byte authentication tag format.

## Requirements

- iOS 9.0+
- Xcode project integration
- Swift 5 for the `Coala` target

```bash
xcodebuild -project Coala.xcodeproj -scheme Coala -sdk iphonesimulator build
xcodebuild -project Coala.xcodeproj -scheme Coala -sdk iphonesimulator test
```

To add Coala to an application:

1. Add this repository as a
   [submodule](https://git-scm.com/book/en/v2/Git-Tools-Submodules).
2. Drag `Coala.xcodeproj` into your application's Xcode project or workspace.
3. Add `Coala.framework` and `Curve25519.framework` to the application target's
   embedded frameworks.

## Quick Start

```swift
import Coala
import Foundation

let server = try Coala(transport: .udp(port: 5683))

server.addResource(
    CoAPResource(method: .get, path: "/msg") { _ in
        return (.content, "Hello from Coala Swift")
    }
)

let client = try Coala(transport: .udp(port: 0))
let url = URL(string: "coap://127.0.0.1:5683/msg")

var request = CoAPMessage(type: .confirmable, method: .get, url: url)
request.onResponse = { response in
    switch response {
    case let .message(message, from):
        print("Response from \(from): \(message.payload?.string ?? "")")
    case let .error(error):
        print("Request failed: \(error)")
    }
}

try client.send(request)
```

## Main API

### `Coala`

| API | Description |
| --- | --- |
| `Coala(transport:)` | Creates a stack and starts the selected transport. |
| `Transport.udp(port:)` | UDP transport bound to the given local port. Use `0` for an ephemeral port. |
| `Transport.tcp(host:port:)` | TCP transport using Coala's custom frame format. |
| `restart()` | Stops and starts the current transport. |
| `stop()` | Stops listening and closes the active socket. |
| `set(transport:completion:)` | Replaces the transport and calls `completion` after it is ready. |
| `send(_:)` | Runs outbound layers, serializes the message, and sends it. |
| `send(_:block2DownloadProgress:)` | Sends a request and reports accumulated Block2/ARQ download data. |
| `addResource(_:)` | Registers a server-side resource. |
| `removeResources(forPath:)` | Removes all resources for a path. |
| `startObserving(url:onUpdate:)` | Sends `GET` with Observe option `0` and calls `onUpdate` for notifications. |
| `stopObserving(url:onStop:)` | Sends `GET` with Observe option `1` and removes the local registration. |
| `configureMessagePool(...)` | Configures retransmit interval and attempt count for confirmable messages. |
| `configureMessagePoolTimeouts(for:)` | Sets longer resend intervals for selected URI/path patterns. |
| `getStatistics(...)`, `flushStatistics(...)` | Reads and clears direct/proxy delivery counters. |
| `resourceDiscovery.run(...)` | Runs multicast discovery and returns responses by source address. |

Static API:

- `Coala.defaultPort` - `5683`.
- `Coala.logger` - logger for debug, info, warning, verbose, and error messages.
- `Coala.curveKeyPairData` - current Curve25519 key pair serialized as `Data`.
- `Coala.frameworkVersion` - framework version from the bundle.

### Resources

| Class | Description |
| --- | --- |
| `CoAPResource` | Regular resource with `method`, `path`, and handler. |
| `ObservableResource` | `GET` resource with Observe support and `notifyObservers()`. |

Example `POST` resource:

```swift
server.addResource(
    CoAPResource(method: .post, path: "/config") { request in
        print("Query: \(request.query)")
        print("Payload: \(request.payload?.string ?? "")")
        return (.changed, nil)
    }
)
```

When a resource is no longer available:

```swift
server.removeResources(forPath: "/config")
```

## Messages and Methods

### CoAP Methods

| Method | Purpose |
| --- | --- |
| `.get` | Read a resource representation or state. |
| `.post` | Send a command or create/update subordinate state. |
| `.put` | Replace or set resource state. |
| `.delete` | Delete a resource or clear state. |

Exact semantics are defined by the server-side handler, as in CoAP.

### Reliability Types

| Type | Purpose |
| --- | --- |
| `.confirmable` (`CON`) | Requires ACK/RST. The message pool retransmits until timeout. |
| `.nonConfirmable` (`NON`) | Sends without requiring ACK. Used by discovery. |
| `.acknowledgement` (`ACK`) | Acknowledges a CON message. |
| `.reset` (`RST`) | Rejects a message or Observe notification. |

### `CoAPMessage`

| API | Description |
| --- | --- |
| `CoAPMessage(type:code:messageId:)` | Creates a message with explicit reliability and code. |
| `CoAPMessage(type:method:url:)` | Creates a request from a method and optional URL. |
| `CoAPMessage(ackTo:from:code:)` | Creates an ACK response to an incoming request. |
| `CoAPMessage(type:code:inResponseTo:from:)` | Creates a response with token/address copied from a request. |
| `url` | Reads/writes URI through CoAP options: scheme, host, port, path, query. |
| `scheme` | `.coap` or `.coapSecure`; `coaps://` enables secure mode. |
| `query` | URI query as `[URLQueryItem]`. |
| `payload` | Binary or UTF-8 payload as `Data` or `String`. |
| `onResponse` | Response callback. Assigning it generates a token if one is missing. |
| `peerPublicKey` | Expected peer key for validation, or received peer key on responses. |
| `proxyViaAddress` | Optional proxy endpoint for outgoing messages. |
| `setOption(...)`, `getOptions(...)` | Set and read CoAP options. |
| `getStringOptions(...)`, `getIntegerOptions(...)`, `getOpaqueOptions(...)` | Typed option readers. |

Responses are delivered through `onResponse`:

```swift
var message = CoAPMessage(
    type: .confirmable,
    method: .get,
    url: URL(string: "coap://192.168.1.10:5683/info")
)

message.onResponse = { response in
    switch response {
    case let .message(message, from):
        print("Response from \(from): \(message.payload?.string ?? "")")
    case let .error(error):
        print("Request failed: \(error)")
    }
}

try coala.send(message)
```

## Discovery

`ResourceDiscovery.run(path:timeout:completion:)` works only with UDP transport:

```swift
coala.resourceDiscovery.run(path: "info", timeout: 2.0) { peers in
    for (address, message) in peers {
        print("\(address): \(message.payload?.string ?? "")")
    }
}
```

Defaults used by Coala:

- multicast group: `224.0.0.187`
- port: `5683`
- path: `info`
- request: `NON GET coap://224.0.0.187:5683/info`

The discovery service registers an internal `/info` resource and returns the
local resource list as a link-format payload.

## Observe

Server-side:

```swift
let temperature = ObservableResource(path: "/temperature") { _ in
    return (.content, "23.4")
}

server.addResource(temperature)
temperature.notifyObservers()
```

Client-side:

```swift
let url = URL(string: "coap://192.168.1.10:5683/temperature")!

client.startObserving(url: url) { response in
    if case let .message(message, _) = response {
        print(message.payload?.string ?? "")
    }
}

client.stopObserving(url: url)
```

Observe tokens are deterministic from the URL. Notifications are filtered by
Observe sequence number. When `Max-Age` expires, the client re-registers
automatically.

## Secure Coala (`coaps`)

Use a URL with the `coaps` scheme. The handshake starts automatically:

```swift
let url = URL(string: "coaps://192.168.1.10:5683/secure")
var request = CoAPMessage(type: .confirmable, method: .get, url: url)
request.payload = "encrypted payload"
request.onResponse = handleResponse

try coala.send(request)
```

Internally:

- Curve25519 key agreement.
- HKDF-SHA256 derives two AES keys and two IVs.
- Payload and encrypted URI are carried through Coala custom options.
- AES-GCM tag is truncated to 12 bytes for Coala compatibility.
- Set `peerPublicKey` on an outgoing message to validate the peer during
  handshake.

## Blockwise and Large Payloads

Payloads larger than `1024` bytes are split into Block1/Block2 segments. For
Coala peers, the stack also uses selective-repeat ARQ with option
`selectiveRepeatWindowSize` (`3001`) to send a window of blocks and reassemble
the payload on the receiver.

Use `block2DownloadProgress` for large response downloads:

```swift
try coala.send(request, block2DownloadProgress: { data in
    print("Downloaded \(data.count) bytes")
})
```

The ARQ send window can be tuned per `Coala` instance:

```swift
coala.arqWindowSize = 8
```

## Logging

Set `Coala.logger` to any type that conforms to `CoalaLogger`:

```swift
final class AppLogger: CoalaLogger {
    func log(_ message: String, level: LogLevel, asynchronous: Bool) {
        print("[\(level)] \(message)")
    }
}

Coala.logger = AppLogger()
```

If the application uses
[`CocoaLumberjack`](https://github.com/CocoaLumberjack/CocoaLumberjack), the
repository includes `Extensions/DDLog+CoalaLogger.swift`.

## Serializer API

`CoAPSerializer` and `CoAPTcpSerializer` are internal implementation details in
the framework target. They encode/decode standard CoAP datagrams and Coala TCP
frames respectively.

Coala TCP frame format:

| Field | Size |
| --- | --- |
| delimiter `M` | 1 byte |
| IPv4 address | 4 bytes |
| port | 2 bytes |
| payload size | 2 bytes |
| CoAP payload | payload size bytes |

## How Coala Differs from CoAP

CoAP is a standard application protocol: message format, methods, response
codes, options, UDP transport, reliability model, Observe, Blockwise, and
discovery conventions. Coala Swift uses the CoAP message model and wire format
for basic UDP datagrams, but adds compatibility with the Coala ecosystem.

Key differences:

- Discovery uses the Coala convention: multicast `224.0.0.187`, path `info`,
  and port `5683`. This is not the generic `/.well-known/core` discovery
  endpoint.
- `coaps` here is not DTLS. Secure mode is implemented at the Coala layer with
  Curve25519 handshake, HKDF-SHA256, AES-GCM, and custom CoAP options.
- Coala defines custom options: `uriScheme` (`2111`),
  `selectiveRepeatWindowSize` (`3001`), `proxySecurityId` (`3004`),
  `handshakeType` (`3999`), `sessionNotFound` (`4001`), `sessionExpired`
  (`4003`), and `coapsUri` (`4005`).
- Large messages can use Coala selective-repeat ARQ on top of Block1/Block2,
  not only basic CoAP blockwise exchange.
- TCP transport uses a custom Coala frame format, not RFC 8323 CoAP-over-TCP
  framing.
- The API is organized around a client/server object model: `Coala`, resources,
  callbacks, observe registry, message pool, and statistics.

In short: regular CoAP peers can understand simple UDP CoAP datagrams, but Coala
features such as secure mode, Coala TCP framing, selective-repeat ARQ, and the
discovery payload require Coala extension support on the other side.
