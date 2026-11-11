import Foundation
import Network
import SystemConfiguration
import ClipboardCore

enum SubnetSweeper {
    /// Widest subnet swept: a /22 (1022 hosts). Larger LANs sweep the /22 around us.
    static let maxPrefixWidth = 22

    /// Host addresses of the subnet given by `netmask` (capped at a /22), excluding
    /// the network, broadcast and own addresses.
    static func hostAddresses(ownIPv4: String, netmask: String) -> [String] {
        guard let ip = ipv4Value(ownIPv4), let mask = ipv4Value(netmask) else { return [] }
        let cappedMask = mask | (UInt32.max << UInt32(32 - maxPrefixWidth))
        let network = ip & cappedMask
        let broadcast = network | ~cappedMask
        guard broadcast > network + 1 else { return [] }

        var result: [String] = []
        for address in (network + 1)..<broadcast where address != ip {
            result.append(ipv4String(address))
        }
        return result
    }

    private static func ipv4Value(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func ipv4String(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}

extension SubnetSweeper {
    struct InterfaceAddress: Equatable {
        let name: String
        let ip: String
        let mask: String
        /// False for point-to-point links (VPN `utunN`, PPP), which are never swept.
        var isBroadcastCapable = true
    }

    /// The LAN interface to sweep: the primary (default-route) interface when it is a
    /// broadcast LAN with hosts to probe, else the next such candidate. Point-to-point
    /// links are never chosen, so a full-tunnel VPN (primary `utunN`) does not aim the
    /// sweep into the remote network or leave it with nothing to probe.
    static func selectInterface(_ candidates: [InterfaceAddress], primaryInterface: String?) -> InterfaceAddress? {
        let sweepable = candidates.filter {
            $0.isBroadcastCapable && !hostAddresses(ownIPv4: $0.ip, netmask: $0.mask).isEmpty
        }
        if let primaryInterface, let primary = sweepable.first(where: { $0.name == primaryInterface }) {
            return primary
        }
        return sweepable.first
    }

    /// Name of the interface carrying the default IPv4 route, e.g. "en0" or "en7".
    static func primaryIPv4InterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "ClipboardSS" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    static func ownIPv4AndMask() -> (ip: String, mask: String)? {
        let selected = selectInterface(activeIPv4Interfaces(), primaryInterface: primaryIPv4InterfaceName())
        return selected.map { ($0.ip, $0.mask) }
    }

    /// Up, non-loopback IPv4 interfaces in system order, point-to-point ones flagged.
    static func activeIPv4Interfaces() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard ptr.pointee.ifa_addr != nil, ptr.pointee.ifa_netmask != nil else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)

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
            let isBroadcastCapable = (flags & IFF_BROADCAST) == IFF_BROADCAST && (flags & IFF_POINTOPOINT) == 0
            result.append(InterfaceAddress(
                name: name,
                ip: hostString,
                mask: maskString,
                isBroadcastCapable: isBroadcastCapable
            ))
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

    static func probe(host: String, timeoutMs: Int) async -> Peer? {
        let request = HTTPRequest(method: "GET", path: "/v1/id", headers: [:], body: Data())
        let bytes = HTTPCodec.encodeRequest(request, host: "\(host):51888")
        guard
            let data = try? await exchange(bytes, host: host, timeoutMs: timeoutMs),
            let response = try? HTTPCodec.parseResponse(data),
            response.statusCode == 200,
            let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let idStr = obj["deviceId"] as? String,
            let id = UUID(uuidString: idStr)
        else {
            return nil
        }

        let name = (obj["deviceName"] as? String) ?? host
        let version = (obj["v"] as? Int) ?? 1
        return Peer(id: id, name: name, host: host, port: 51888, protocolVersion: version)
    }

    /// Sends one encoded HTTP request to `host:51888` and returns the raw response.
    static func exchange(_ data: Data, host: String, timeoutMs: Int) async throws -> Data {
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

                    if buffer.data.count > HTTPCodec.maxBodySize + HTTPCodec.maxHeaderSize {
                        timeoutTask.cancel()
                        respond(.failure(URLError(.dataLengthExceedsMaximum)))
                        return
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
