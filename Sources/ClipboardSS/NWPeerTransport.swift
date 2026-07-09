import Foundation
import Network
import ClipboardCore

public final class NWPeerTransport: PeerTransport, @unchecked Sendable {
    public init() {}

    static func endpoint(for peer: Peer) -> NWEndpoint {
        if peer.port == 0 {
            return .service(
                name: peer.host,
                type: "_clipboardss._tcp",
                domain: "local.",
                interface: nil
            )
        }

        guard let port = NWEndpoint.Port(rawValue: peer.port) else {
            return .hostPort(host: NWEndpoint.Host(peer.host), port: 0)
        }
        return .hostPort(host: NWEndpoint.Host(peer.host), port: port)
    }
    
    public func send(_ data: Data, to peer: Peer) async throws -> Data {
        let ep = Self.endpoint(for: peer)
        logToFile("NWPeerTransport: send initiated to peer \(peer.name), resolved endpoint: \(ep)")
        
        if peer.port != 0, NWEndpoint.Port(rawValue: peer.port) == nil {
            logToFile("NWPeerTransport: Invalid port: \(peer.port)")
            throw URLError(.badURL)
        }
        let connection = NWConnection(to: ep, using: .tcp)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            final class RequestState: @unchecked Sendable {
                var hasResponded = false
                let lock = NSLock()
            }
            let reqState = RequestState()
            
            @Sendable func respond(_ result: Result<Data, Error>) {
                reqState.lock.lock()
                defer { reqState.lock.unlock() }
                if !reqState.hasResponded {
                    reqState.hasResponded = true
                    connection.cancel()
                    switch result {
                    case .success(let responseData):
                        logToFile("NWPeerTransport: send request successful, response \(responseData.count) bytes")
                        continuation.resume(returning: responseData)
                    case .failure(let error):
                        logToFile("NWPeerTransport: send request failed with error: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    // Cancelled because a response (or other failure) already arrived.
                    // This is NOT a timeout, so do not report one.
                    return
                }
                logToFile("NWPeerTransport: send request timed out (10s)")
                respond(.failure(URLError(.timedOut)))
            }
            
            connection.stateUpdateHandler = { state in
                logToFile("NWPeerTransport: connection state changed to: \(state)")
                switch state {
                case .ready:
                    logToFile("NWPeerTransport: connection is ready, sending \(data.count) bytes...")
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            logToFile("NWPeerTransport: connection.send failed with error: \(error)")
                            timeoutTask.cancel()
                            respond(.failure(error))
                        } else {
                            logToFile("NWPeerTransport: connection.send succeeded. Awaiting response...")
                            final class ResponseBuffer: @unchecked Sendable {
                                var data = Data()
                            }
                            let buffer = ResponseBuffer()

                            @Sendable func receiveResponse() {
                                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { responseData, _, isComplete, receiveError in
                                    if let receiveError = receiveError {
                                        timeoutTask.cancel()
                                        logToFile("NWPeerTransport: connection.receive failed with error: \(receiveError)")
                                        respond(.failure(receiveError))
                                        return
                                    }

                                    if let responseData {
                                        buffer.data.append(responseData)
                                    }

                                    do {
                                        _ = try HTTPCodec.parseResponse(buffer.data)
                                        timeoutTask.cancel()
                                        logToFile("NWPeerTransport: connection.receive succeeded, read \(buffer.data.count) bytes")
                                        respond(.success(buffer.data))
                                    } catch HTTPCodecError.incomplete where !isComplete {
                                        receiveResponse()
                                    } catch {
                                        timeoutTask.cancel()
                                        logToFile("NWPeerTransport: connection.receive returned invalid response: \(error)")
                                        respond(.failure(error))
                                    }
                                }
                            }

                            receiveResponse()
                        }
                    })
                case .failed(let error):
                    logToFile("NWPeerTransport: connection entered failed state: \(error)")
                    timeoutTask.cancel()
                    respond(.failure(error))
                case .cancelled:
                    logToFile("NWPeerTransport: connection cancelled")
                    timeoutTask.cancel()
                    respond(.failure(URLError(.cancelled)))
                case .waiting(let error):
                    logToFile("NWPeerTransport: connection waiting with error: \(error)")
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }
}
