import ClipboardCore
import Foundation
import Network
import Testing
@testable import ClipboardSS

@Suite("Network peer transport")
struct NWPeerTransportTests {
    @Test("Bonjour peers with no numeric port connect through service endpoint")
    func bonjourPeerUsesServiceEndpointWhenPortIsZero() {
        let peer = Peer(
            id: UUID(),
            name: "Phone",
            host: "Phone Service",
            port: 0
        )

        let endpoint = NWPeerTransport.endpoint(for: peer)

        guard case .service(let name, let type, let domain, _) = endpoint else {
            Issue.record("Expected a service endpoint, got \(endpoint)")
            return
        }
        #expect(name == "Phone Service")
        #expect(type == "_clipboardss._tcp")
        #expect(domain == "local.")
    }

    @Test("Immediate responses are not misreported as timeouts")
    func immediateResponseIsNotReportedAsTimeout() async throws {
        // A loopback server that replies instantly. The receive handler cancels the
        // timeout task the moment the response arrives; a cancelled timeout must not
        // resolve the request as a failure. Run repeatedly to flush out the race that
        // previously made pairing fail intermittently.
        let listener = try NWListener(using: .tcp)
        let responseBody = Data("OK".utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: responseBody)
        let responseBytes = HTTPCodec.encodeResponse(response)

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                connection.send(content: responseBytes, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        // Await the listener reaching `.ready`, at which point it has a bound port.
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if didResume { return false }
                didResume = true
                return true
            }
        }
        let guardState = ResumeGuard()
        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardState.claim() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if guardState.claim() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let port = try #require(readyPort == 0 ? nil : readyPort)

        let transport = NWPeerTransport()
        let peer = Peer(id: UUID(), name: "Loopback", host: "127.0.0.1", port: UInt16(port))
        let request = HTTPRequest(method: "POST", path: "/v1/ping", headers: [:], body: Data())
        let requestBytes = HTTPCodec.encodeRequest(request, host: "127.0.0.1")

        for _ in 0..<25 {
            let received = try await transport.send(requestBytes, to: peer)
            let parsed = try HTTPCodec.parseResponse(received)
            #expect(parsed.statusCode == 200)
        }
    }
}
