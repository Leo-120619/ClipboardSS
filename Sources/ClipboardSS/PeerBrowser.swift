import Foundation
import Network
import Combine
import ClipboardCore
import OSLog

func logToFile(_ message: String) {
    guard ProcessInfo.processInfo.environment["CLIPBOARDSS_DEBUG_LOG"] == "1" else { return }

    let logMessage = "[\(Date())] \(message)\n"
    if let data = logMessage.data(using: .utf8) {
        let fileURL = URL(fileURLWithPath: "/tmp/clipboardss_debug.log")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}

@MainActor
public final class PeerBrowser: ObservableObject {
    @Published public private(set) var peers: [Peer] = []
    
    private let browser: NWBrowser
    private let identityId: UUID
    private let logger = Logger(subsystem: "com.local.ClipboardSS", category: "PeerBrowser")
    private var lastSeenPeers: [UUID: (peer: Peer, lastSeen: Date)] = [:]
    private static let peerGracePeriod: TimeInterval = 10
    
    public init(identityId: UUID) {
        self.identityId = identityId
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_clipboardss._tcp", domain: "local.")
        self.browser = NWBrowser(for: descriptor, using: .tcp)
        
        logToFile("Initializing PeerBrowser with identity: \(identityId)")
        
        self.browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                logToFile("browseResultsChangedHandler fired, count: \(results.count)")
                self?.updatePeers(from: results)
            }
        }
        
        self.browser.stateUpdateHandler = { [logger] state in
            logToFile("PeerBrowser state changed to: \(state)")
            logger.info("PeerBrowser state changed to: \(String(describing: state), privacy: .public)")
            if case .failed(let error) = state {
                logToFile("PeerBrowser failed with error: \(error)")
                logger.error("PeerBrowser failed with error: \(String(describing: error), privacy: .public)")
            }
        }
    }
    
    public func start() {
        logToFile("Starting browser")
        browser.start(queue: .main)
    }
    
    public func stop() {
        logToFile("Stopping browser")
        browser.cancel()
    }
    
    private func updatePeers(from results: Set<NWBrowser.Result>) {
        var newPeers: [Peer] = []
        let now = Date()
        
        logToFile("updatePeers called with \(results.count) results")
        logger.info("updatePeers called with \(results.count, privacy: .public) results")
        
        for result in results {
            logToFile("Examining result: \(result.endpoint), metadata: \(String(describing: result.metadata))")
            logger.debug("Examining result: \(String(describing: result.endpoint), privacy: .public)")
            if case .service(let name, _, _, _) = result.endpoint {
                guard case let .bonjour(txt) = result.metadata else {
                    logToFile("Missing Bonjour TXT metadata for \(result.endpoint)")
                    logger.warning("Missing Bonjour TXT metadata for \(String(describing: result.endpoint), privacy: .public)")
                    continue
                }
                
                logToFile("Found Bonjour TXT: \(txt.dictionary)")
                
                if Self.isSelfService(txt: txt.dictionary, identityId: identityId) {
                    logToFile("Ignoring self Bonjour service \(name)")
                    logger.debug("Ignoring self Bonjour service \(name, privacy: .public)")
                    continue
                }

                guard let peer = Self.peer(serviceName: name, txt: txt.dictionary, identityId: identityId) else {
                    logToFile("Rejected Bonjour service \(name) with TXT \(txt.dictionary)")
                    logger.warning("Rejected Bonjour service \(name, privacy: .public) with TXT \(String(describing: txt.dictionary), privacy: .public)")
                    continue
                }
                
                logToFile("Parsed peer \(peer.name) (\(peer.id.uuidString))")
                logger.info("Parsed peer \(peer.name, privacy: .public) (\(peer.id.uuidString, privacy: .public))")
                newPeers.append(peer)
                lastSeenPeers[peer.id] = (peer: peer, lastSeen: now)
            } else {
                logToFile("Endpoint is not a service: \(result.endpoint)")
                logger.warning("Endpoint is not a service: \(String(describing: result.endpoint), privacy: .public)")
            }
        }
        
        let peersToPublish = Self.peersForPublish(
            current: newPeers,
            lastSeen: lastSeenPeers,
            now: now,
            gracePeriod: Self.peerGracePeriod
        )
        lastSeenPeers = Dictionary(uniqueKeysWithValues: peersToPublish.map { peer in
            (peer.id, lastSeenPeers[peer.id] ?? (peer: peer, lastSeen: now))
        })

        logToFile("Publishing peers: \(peersToPublish.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", "))")
        logger.info("Publishing peers: \(peersToPublish.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", "), privacy: .public)")
        self.peers = peersToPublish
    }

    static func peersForPublish(
        current: [Peer],
        lastSeen: [UUID: (peer: Peer, lastSeen: Date)],
        now: Date,
        gracePeriod: TimeInterval
    ) -> [Peer] {
        var merged: [UUID: Peer] = [:]
        for (id, entry) in lastSeen where now.timeIntervalSince(entry.lastSeen) <= gracePeriod {
            merged[id] = entry.peer
        }
        for peer in current {
            merged[peer.id] = peer
        }
        return merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func peer(serviceName: String, txt: [String: String], identityId: UUID) -> Peer? {
        guard let vStr = txtValue("v", in: txt), vStr == "1",
              let deviceIdStr = txtValue("deviceId", in: txt),
              let deviceId = UUID(uuidString: deviceIdStr) else {
            return nil
        }

        guard deviceId != identityId else {
            return nil
        }

        let deviceName = txtValue("deviceName", in: txt).flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
        return Peer(id: deviceId, name: deviceName, host: serviceName, port: 0)
    }

    private static func isSelfService(txt: [String: String], identityId: UUID) -> Bool {
        guard let deviceIdStr = txtValue("deviceId", in: txt),
              let deviceId = UUID(uuidString: deviceIdStr) else {
            return false
        }
        return deviceId == identityId
    }

    private static func txtValue(_ targetKey: String, in txt: [String: String]) -> String? {
        if let value = txt[targetKey] { return value }
        let lowerTarget = targetKey.lowercased()
        for (key, val) in txt {
            if key.lowercased() == lowerTarget {
                return val
            }
        }
        return nil
    }
}
