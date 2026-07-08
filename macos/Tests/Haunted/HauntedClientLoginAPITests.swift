import Testing
import Foundation
@testable import Ghostty

/// Builds an HTTP response for whatever URL the request actually carried, so a
/// wrong request URL cannot be papered over by a hard-coded response URL.
private func httpResponse(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    else {
        throw URLError(.badServerResponse)
    }
    return response
}

private let startResponseJSON = Data(
    #"{"id":"req-1","url":"/client-login/approve?id=req-1"}"#.utf8)

private let redeemResponseJSON = Data(
    #"""
    {"token":"tok-1","username":"luiz","client_name":"term-1",
     "control_port":"9443","ca_pem":"-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n"}
    """#.utf8)

/// TEST_PLAN §4.5 — API-01…07, `HauntedClientLoginAPI` over the §5.2 HTTP seam.
///
/// Every case runs against `HauntedStubURLProtocol` on an ephemeral session: no
/// socket is ever opened, and the requests asserted on are the ones Foundation
/// actually issued (bodies drained from `httpBodyStream` at the stub boundary),
/// not a wrapper's idea of them.
///
/// `.serialized` because the stub's handler and request log are necessarily
/// static — Foundation instantiates `URLProtocol` subclasses itself.
@Suite(.serialized)
struct HauntedClientLoginAPITests {
    // MARK: API-01

    @Test("API-01: start POSTs the API path with client_name and the injected device_label")
    func startRequestShape() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 200)
            return (response, startResponseJSON)
        }

        let consoleURL = try #require(URL(string: "https://console.example.com"))
        let started = try await HauntedClientLoginAPI.start(
            consoleURL: consoleURL,
            session: HauntedStubURLProtocol.makeSession(),
            deviceLabel: "luiz-laptop")

        #expect(started.id == "req-1")
        #expect(started.url == "/client-login/approve?id=req-1")

        let requests = HauntedStubURLProtocol.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://console.example.com/api/v0/client-login/start")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        // The body is an httpBodyStream by the time a URLProtocol sees it; the
        // stub drains it, so this asserts on the bytes that would have gone out.
        let body = try JSONDecoder().decode(
            [String: String].self, from: HauntedStubURLProtocol.body(of: request))
        #expect(body == ["client_name": "term", "device_label": "luiz-laptop"])
    }

    // MARK: API-02

    @Test("API-02: a console URL's own path and query are both replaced, query becomes nil")
    func consoleURLPathAndQueryReplaced() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 200)
            return (response, startResponseJSON)
        }

        let consoleURL = try #require(URL(string: "https://c.example/x?y=1"))
        _ = try await HauntedClientLoginAPI.start(
            consoleURL: consoleURL,
            session: HauntedStubURLProtocol.makeSession(),
            deviceLabel: "d")

        let request = try #require(HauntedStubURLProtocol.requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/api/v0/client-login/start")
        #expect(url.query == nil, "the console URL's query must not survive into the API call")
        #expect(url.absoluteString == "https://c.example/api/v0/client-login/start")
    }

    @Test("API-02: redeem replaces path and query the same way")
    func redeemURLPathAndQueryReplaced() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 200)
            return (response, redeemResponseJSON)
        }

        let consoleURL = try #require(URL(string: "https://c.example/x?y=1"))
        let redeemed = try await HauntedClientLoginAPI.redeem(
            consoleURL: consoleURL,
            id: "req-1",
            code: "123456",
            session: HauntedStubURLProtocol.makeSession())

        #expect(redeemed.token == "tok-1")
        #expect(redeemed.clientName == "term-1")
        #expect(redeemed.controlPort == "9443")

        let request = try #require(HauntedStubURLProtocol.requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/api/v0/client-login/redeem")
        #expect(url.query == nil)

        let body = try JSONDecoder().decode(
            [String: String].self, from: HauntedStubURLProtocol.body(of: request))
        #expect(body == ["id": "req-1", "code": "123456"])
    }

    // MARK: API-03

    @Test("API-03: HTTP 400 surfaces the console's body text as the error message")
    func httpErrorUsesResponseBody() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 400)
            return (response, Data("bad code\n".utf8))
        }

        let consoleURL = try #require(URL(string: "https://console.example.com"))
        do {
            _ = try await HauntedClientLoginAPI.redeem(
                consoleURL: consoleURL,
                id: "req-1",
                code: "000000",
                session: HauntedStubURLProtocol.makeSession())
            Issue.record("redeem should throw on HTTP 400")
        } catch let error as HauntedCLIError {
            #expect(error.message == "bad code")
            #expect(error.errorDescription == "bad code")
        }
    }

    // MARK: API-04

    @Test("API-04: HTTP 500 with an empty body falls back to the status line")
    func httpErrorEmptyBody() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 500)
            return (response, Data())
        }

        let consoleURL = try #require(URL(string: "https://console.example.com"))
        do {
            _ = try await HauntedClientLoginAPI.start(
                consoleURL: consoleURL,
                session: HauntedStubURLProtocol.makeSession(),
                deviceLabel: "d")
            Issue.record("start should throw on HTTP 500")
        } catch let error as HauntedCLIError {
            #expect(error.message == "Console returned HTTP 500")
        }
    }

    // MARK: API-05

    @Test("API-05: a non-HTTP response is rejected rather than parsed")
    func nonHTTPResponse() async throws {
        HauntedStubURLProtocol.reset { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = URLResponse(
                url: url,
                mimeType: "application/json",
                expectedContentLength: startResponseJSON.count,
                textEncodingName: "utf-8")
            return (response, startResponseJSON)
        }

        let consoleURL = try #require(URL(string: "https://console.example.com"))
        do {
            _ = try await HauntedClientLoginAPI.start(
                consoleURL: consoleURL,
                session: HauntedStubURLProtocol.makeSession(),
                deviceLabel: "d")
            Issue.record("start should throw when the response is not an HTTPURLResponse")
        } catch let error as HauntedCLIError {
            #expect(error.message == "No HTTP response from Console")
        }
    }

    // MARK: API-06

    @Test("API-06: a 200 with unparseable JSON propagates the decode error")
    func unparseableJSONPropagates() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 200)
            return (response, Data("not json{".utf8))
        }

        let consoleURL = try #require(URL(string: "https://console.example.com"))
        do {
            _ = try await HauntedClientLoginAPI.start(
                consoleURL: consoleURL,
                session: HauntedStubURLProtocol.makeSession(),
                deviceLabel: "d")
            Issue.record("start should not swallow a malformed console response")
        } catch is DecodingError {
            // Expected: the decode failure reaches the caller unmasked.
        } catch let error as HauntedCLIError {
            Issue.record("decode error was masked as HauntedCLIError: \(error.message)")
        }
    }

    // MARK: API-07

    @Test("API-07: a plaintext non-loopback console throws before any request is issued")
    func plaintextConsoleNeverReachesTheNetwork() async throws {
        HauntedStubURLProtocol.reset { _ in
            Issue.record("a request was issued for a rejected console URL")
            throw URLError(.unsupportedURL)
        }

        let evil = try #require(URL(string: "http://evil.com"))
        let session = HauntedStubURLProtocol.makeSession()

        do {
            _ = try await HauntedClientLoginAPI.start(
                consoleURL: evil, session: session, deviceLabel: "d")
            Issue.record("start should reject a plaintext non-loopback console")
        } catch let error as HauntedCLIError {
            #expect(error.message == "Console URL must use https")
        }

        do {
            _ = try await HauntedClientLoginAPI.redeem(
                consoleURL: evil, id: "req-1", code: "123456", session: session)
            Issue.record("redeem should reject a plaintext non-loopback console")
        } catch let error as HauntedCLIError {
            #expect(error.message == "Console URL must use https")
        }

        // The point of the case: the credential-bearing code must not leave the
        // machine at all. Throwing after a request went out would still be a leak.
        #expect(HauntedStubURLProtocol.requests.isEmpty)
    }

    /// The loopback carve-out is what makes API-07's assertion meaningful: the
    /// gate is a scheme+host decision, not a blanket "no http".
    @Test("API-07 (contrast): http loopback is allowed and does issue a request")
    func loopbackConsoleIsAllowed() async throws {
        HauntedStubURLProtocol.reset { request in
            let response = try httpResponse(for: request, status: 200)
            return (response, startResponseJSON)
        }

        let consoleURL = try #require(URL(string: "http://127.0.0.1:8080"))
        _ = try await HauntedClientLoginAPI.start(
            consoleURL: consoleURL,
            session: HauntedStubURLProtocol.makeSession(),
            deviceLabel: "d")

        #expect(HauntedStubURLProtocol.requests.count == 1)
        let url = try #require(HauntedStubURLProtocol.requests.first?.url)
        #expect(url.absoluteString == "http://127.0.0.1:8080/api/v0/client-login/start")
    }
}
