import Foundation
import Network
import ClipboardCore

enum SubnetSweeper {
    static func hostAddresses(ownIPv4: String, netmask: String) -> [String] {
        let ipParts = ownIPv4.split(separator: ".").compactMap { UInt8($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt8($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return [] }

        let prefix = [ipParts[0], ipParts[1], ipParts[2]]
        var result: [String] = []
        for last in 1...254 {
            let addr = "\(prefix[0]).\(prefix[1]).\(prefix[2]).\(last)"
            if addr == ownIPv4 { continue }
            result.append(addr)
        }
        return result
    }
}

extension SubnetSweeper {
    static func ownIPv4AndMask() -> (ip: String, mask: String)? {
        var result: (String, String)?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            getnameinfo(
                ptr.pointee.ifa_netmask,
                socklen_t(ptr.pointee.ifa_netmask.pointee.sa_len),
                &mask,
                socklen_t(mask.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let hostString = host.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            let maskString = mask.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            result = (hostString, maskString)
        }

        return result
    }

    static func sweep(transport: PeerTransport? = nil, timeoutMs: Int = 500, concurrency: Int = 32) async -> [Peer] {
        guard let (ip, mask) = ownIPv4AndMask() else { return [] }
        let hosts = hostAddresses(ownIPv4: ip, netmask: mask)

        return await withTaskGroup(of: Peer?.self) { group in
            var found: [Peer] = []
            var index = 0

            func addTask(_ host: String) {
                group.addTask {
                    await probe(host: host, timeoutMs: timeoutMs)
                }
            }

            while index < hosts.count && index < concurrency {
                addTask(hosts[index])
                index += 1
            }

            while let peer = await group.next() {
                if let peer {
                    found.append(peer)
                }
                if index < hosts.count {
                    addTask(hosts[index])
                    index += 1
                }
            }

            return found
        }
    }

    private static func probe(host: String, timeoutMs: Int) async -> Peer? {
        let request = HTTPRequest(method: "GET", path: "/v1/id", headers: [:], body: Data())
        let bytes = HTTPCodec.encodeRequest(request, host: "\(host):51888")
        guard
            let data = try? await sendProbe(bytes, host: host, timeoutMs: timeoutMs),
            let response = try? HTTPCodec.parseResponse(data),
            response.statusCode == 200,
            let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let idStr = obj["deviceId"] as? String,
            let id = UUID(uuidString: idStr)
        else {
            return nil
        }

        let name = (obj["deviceName"] as? String) ?? host
        return Peer(id: id, name: name, host: host, port: 51888)
    }

    private static func sendProbe(_ data: Data, host: String, timeoutMs: Int) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: 51888) else {
            throw URLError(.badURL)
        }

        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: port), using: .tcp)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            final class RequestState: @unchecked Sendable {
                var hasResponded = false
                let lock = NSLock()
            }
            final class ResponseBuffer: @unchecked Sendable {
                var data = Data()
            }

            let state = RequestState()
            let buffer = ResponseBuffer()

            @Sendable func respond(_ result: Result<Data, Error>) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.hasResponded else { return }
                state.hasResponded = true
                connection.cancel()
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 1)) * 1_000_000)
                } catch {
                    return
                }
                respond(.failure(URLError(.timedOut)))
            }

            @Sendable func receiveResponse() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { responseData, _, isComplete, receiveError in
                    if let receiveError {
                        timeoutTask.cancel()
                        respond(.failure(receiveError))
                        return
                    }

                    if let responseData {
                        buffer.data.append(responseData)
                    }

                    do {
                        _ = try HTTPCodec.parseResponse(buffer.data)
                        timeoutTask.cancel()
                        respond(.success(buffer.data))
                    } catch HTTPCodecError.incomplete where !isComplete {
                        receiveResponse()
                    } catch {
                        timeoutTask.cancel()
                        respond(.failure(error))
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error {
                            timeoutTask.cancel()
                            respond(.failure(error))
                        } else {
                            receiveResponse()
                        }
                    })
                case .failed(let error):
                    timeoutTask.cancel()
                    respond(.failure(error))
                case .cancelled:
                    timeoutTask.cancel()
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }
}
