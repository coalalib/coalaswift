import Foundation
import Testing
@testable import Coala

@Suite("CoAPMessage url/query options")
struct CoAPMessageUrlQueryTests {

  private func makeMessage() -> CoAPMessage {
    CoAPMessage(type: .confirmable, code: .request(.get))
  }

  // MARK: - query getter

  @Test("query getter rejoins values containing '='")
  func queryValueWithEquals() {
    var message = makeMessage()
    message.setOption(.uriQuery, value: "a=b=c")
    #expect(message.query == [URLQueryItem(name: "a", value: "b=c")])
  }

  @Test("query option without '=' yields a nil item value")
  func queryFlagWithoutValue() {
    var message = makeMessage()
    message.setOption(.uriQuery, value: "flag")
    #expect(message.query == [URLQueryItem(name: "flag", value: nil)])
  }

  @Test("message without query options has a nil query")
  func noQueryOptions() {
    #expect(makeMessage().query == nil)
  }

  // MARK: - url getter

  @Test("url getter percent-encodes '+' and ';' in query values")
  func urlPercentEncodesPlusAndSemicolon() throws {
    var message = makeMessage()
    message.setOption(.uriHost, value: "h.com")
    message.setOption(.uriQuery, value: "x=1+2;3")
    let url = try #require(message.url)
    #expect(url.absoluteString.contains("x=1%2b2%3b3"))
  }

  @Test("url getter is nil without a uriHost option or an address")
  func urlNilWithoutHostAndAddress() {
    #expect(makeMessage().url == nil)
  }

  @Test("url getter falls back to the address host/port and uses a '/' path")
  func urlFallsBackToAddress() {
    var message = makeMessage()
    message.address = Address(host: "10.0.0.5", port: 1234)
    #expect(message.url?.absoluteString == "coap://10.0.0.5:1234/")
  }

  // MARK: - url setter

  @Test("url setter splits path/query into options and derives an address with the default port")
  func urlSetterDecomposesIntoOptions() {
    var message = makeMessage()
    message.url = URL(string: "coap://h.com/a/b?x=1")
    #expect(message.getStringOptions(.uriPath) == ["a", "b"])
    #expect(message.getStringOptions(.uriQuery) == ["x=1"])
    #expect(message.address == Address(host: "h.com", port: 5683))
  }

  @Test("url setter with a host-less url clears the address")
  func urlSetterWithoutHostClearsAddress() {
    var message = makeMessage()
    message.url = URL(string: "coap://h.com/a")
    message.url = URL(string: "/a/b")
    #expect(message.address == nil)
    #expect(message.url == nil)
  }

  @Test("a coaps url sets the coapSecure scheme")
  func coapsUrlSetsSecureScheme() {
    var message = makeMessage()
    message.url = URL(string: "coaps://h.com/x")
    #expect(message.scheme == .coapSecure)
  }

  // MARK: - setOption repeatable semantics

  @Test("a repeatable option accumulates values when set twice")
  func repeatableOptionAppends() {
    var message = makeMessage()
    message.setOption(.uriPath, value: "a")
    message.setOption(.uriPath, value: "b")
    #expect(message.getStringOptions(.uriPath) == ["a", "b"])
  }

  @Test("a non-repeatable option is replaced when set twice")
  func nonRepeatableOptionReplaces() {
    var message = makeMessage()
    message.setOption(.contentFormat, value: 40)
    message.setOption(.contentFormat, value: 50)
    #expect(message.getIntegerOptions(.contentFormat) == [50])
  }
}
