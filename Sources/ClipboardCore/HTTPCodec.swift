import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    
    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    
    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum HTTPCodecError: Error {
    case incomplete
    case invalidFormat
    case payloadTooLarge
    case headersTooLarge
}

public enum HTTPCodec {
    public static let maxBodySize = 20 * 1024 * 1024 // 20 MB
    public static let maxHeaderSize = 16 * 1024

    public static func parseRequest(_ data: Data) throws -> HTTPRequest {
        let range = try headerTerminatorRange(in: data)
        let headData = data[..<range.lowerBound]
        let bodyData = data[range.upperBound...]
        
        guard let headString = String(data: headData, encoding: .utf8) else {
            throw HTTPCodecError.invalidFormat
        }

        var lines = headString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPCodecError.invalidFormat }

        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count == 3 else { throw HTTPCodecError.invalidFormat }

        let method = requestLine[0]
        let path = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                headers[headerParts[0].lowercased()] = headerParts.dropFirst().joined(separator: ": ")
            }
        }

        let body = try resolveBody(bodyData, contentLengthHeader: headers["content-length"])
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    public static func encodeResponse(_ response: HTTPResponse) -> Data {
        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Status"
        }
        
        var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        var finalHeaders = response.headers
        finalHeaders["Content-Length"] = "\(response.body.count)"
        finalHeaders["Connection"] = "close"
        
        for (key, value) in finalHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }
    
    public static func parseResponse(_ data: Data) throws -> HTTPResponse {
        let range = try headerTerminatorRange(in: data)
        let headData = data[..<range.lowerBound]
        let bodyData = data[range.upperBound...]
        
        guard let headString = String(data: headData, encoding: .utf8) else {
            throw HTTPCodecError.invalidFormat
        }

        var lines = headString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPCodecError.invalidFormat }

        let statusLine = lines.removeFirst().components(separatedBy: " ")
        guard statusLine.count >= 2, let statusCode = Int(statusLine[1]) else {
            throw HTTPCodecError.invalidFormat
        }

        var headers: [String: String] = [:]
        for line in lines {
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count >= 2 {
                headers[headerParts[0].lowercased()] = headerParts.dropFirst().joined(separator: ": ")
            }
        }

        let body = try resolveBody(bodyData, contentLengthHeader: headers["content-length"])
        return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    public static func encodeRequest(_ request: HTTPRequest, host: String) -> Data {
        var head = "\(request.method) \(request.path) HTTP/1.1\r\n"
        var finalHeaders = request.headers
        finalHeaders["Content-Length"] = "\(request.body.count)"
        finalHeaders["Host"] = host
        finalHeaders["Connection"] = "close"
        
        for (key, value) in finalHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(request.body)
        return data
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Locates the end of the header block, refusing to look past `maxHeaderSize` bytes
    /// so a peer that never sends a terminator cannot make us buffer without bound.
    private static func headerTerminatorRange(in data: Data) throws -> Range<Data.Index> {
        let searchLimit = maxHeaderSize + headerTerminator.count
        let window = data.prefix(searchLimit)
        if let range = window.range(of: headerTerminator) {
            return range
        }
        if data.count >= searchLimit {
            throw HTTPCodecError.headersTooLarge
        }
        throw HTTPCodecError.incomplete
    }

    /// Validates `Content-Length` and returns the body as standalone `Data` (never a slice),
    /// so callers always see a zero-based buffer.
    private static func resolveBody(_ bodyData: Data, contentLengthHeader: String?) throws -> Data {
        guard let rawLength = contentLengthHeader else {
            return Data(bodyData)
        }
        let trimmed = rawLength.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        // Only a plain run of ASCII digits is a valid length; Int(_:) alone would accept "-1" or "+5".
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            throw HTTPCodecError.invalidFormat
        }
        // All digits but not representable as Int means it is far beyond any allowed size.
        guard let contentLength = Int(trimmed) else {
            throw HTTPCodecError.payloadTooLarge
        }
        if contentLength > maxBodySize {
            throw HTTPCodecError.payloadTooLarge
        }
        if bodyData.count < contentLength {
            throw HTTPCodecError.incomplete
        }
        return Data(bodyData.prefix(contentLength))
    }
}
