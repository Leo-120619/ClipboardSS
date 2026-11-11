import Foundation
import Testing
import ClipboardCore

@Suite("HTTPCodec hostile input")
struct HTTPCodecTests {
    @Test("negative Content-Length in a request throws invalidFormat")
    func testNegativeContentLengthThrowsInvalidFormat() {
        let raw = Data("POST /v1/clip HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        #expect(throws: HTTPCodecError.invalidFormat) {
            _ = try HTTPCodec.parseRequest(raw)
        }
    }

    @Test("negative Content-Length in a response throws invalidFormat")
    func testNegativeContentLengthInResponseThrowsInvalidFormat() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n".utf8)
        #expect(throws: HTTPCodecError.invalidFormat) {
            _ = try HTTPCodec.parseResponse(raw)
        }
    }

    @Test("non-numeric Content-Length throws invalidFormat")
    func testNonNumericContentLengthThrowsInvalidFormat() {
        let request = Data("POST /v1/clip HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)
        #expect(throws: HTTPCodecError.invalidFormat) {
            _ = try HTTPCodec.parseRequest(request)
        }
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n".utf8)
        #expect(throws: HTTPCodecError.invalidFormat) {
            _ = try HTTPCodec.parseResponse(response)
        }
        // A sign prefix is accepted by Int(_:) but is not a plain decimal length.
        let signed = Data("POST /v1/clip HTTP/1.1\r\nContent-Length: +2\r\n\r\nhi".utf8)
        #expect(throws: HTTPCodecError.invalidFormat) {
            _ = try HTTPCodec.parseRequest(signed)
        }
    }

    @Test("headers larger than the limit without a terminator throw headersTooLarge")
    func testHeadersLargerThanLimitThrowHeadersTooLarge() {
        #expect(HTTPCodec.maxHeaderSize == 16 * 1024)
        let raw = Data(repeating: UInt8(ascii: "A"), count: 17 * 1024)
        #expect(throws: HTTPCodecError.headersTooLarge) {
            _ = try HTTPCodec.parseRequest(raw)
        }
        #expect(throws: HTTPCodecError.headersTooLarge) {
            _ = try HTTPCodec.parseResponse(raw)
        }
    }

    @Test("headers below the limit without a terminator are still incomplete")
    func testShortUnterminatedHeadersAreIncomplete() {
        let raw = Data("POST /v1/clip HTTP/1.1\r\nContent-Le".utf8)
        #expect(throws: HTTPCodecError.incomplete) {
            _ = try HTTPCodec.parseRequest(raw)
        }
    }

    @Test("parsed request body is a standalone Data that JSON-decodes")
    func testBodySliceWithNonZeroStartIndexDecodes() throws {
        struct Payload: Codable, Equatable { let v: Int; let name: String }
        let json = try JSONEncoder().encode(Payload(v: 1, name: "Mac"))
        var raw = Data("POST /v1/clip HTTP/1.1\r\nContent-Length: \(json.count)\r\n\r\n".utf8)
        raw.append(json)

        let request = try HTTPCodec.parseRequest(raw)
        #expect(request.body.startIndex == 0)
        #expect(request.body.count == json.count)
        #expect(try JSONDecoder().decode(Payload.self, from: request.body) == Payload(v: 1, name: "Mac"))

        var responseRaw = Data("HTTP/1.1 200 OK\r\nContent-Length: \(json.count)\r\n\r\n".utf8)
        responseRaw.append(json)
        let response = try HTTPCodec.parseResponse(responseRaw)
        #expect(response.body.startIndex == 0)
        #expect(try JSONDecoder().decode(Payload.self, from: response.body) == Payload(v: 1, name: "Mac"))
    }

    @Test("well-formed request still parses")
    func testValidRequestRoundTrips() throws {
        let body = Data("hello".utf8)
        let encoded = HTTPCodec.encodeRequest(
            HTTPRequest(method: "POST", path: "/v1/clip", headers: ["X-Test": "1"], body: body),
            host: "example.local"
        )
        let request = try HTTPCodec.parseRequest(encoded)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/clip")
        #expect(request.headers["x-test"] == "1")
        #expect(request.body == body)
    }
}
