import Foundation
import CryptoKit
import Testing
@testable import ClipboardCore

@Suite("FileSender")
struct FileSenderTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Double] = []
        func record(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let cancelAt: Int
        init(cancelAt: Int) { self.cancelAt = cancelAt }
        func poll() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count > cancelAt }
    }

    private func makeFile(bytes: Int) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("payload.bin")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    private func makeSender(peerId: UUID, key: SymmetricKey, transport: PeerTransport) async throws -> FileSender {
        let store = try await makePairedStore(peerId: peerId, key: key)
        return FileSender(identity: DeviceIdentity(id: UUID(), name: "Mac"), pairedStore: store, transport: transport)
    }

    private let peer = Peer(id: UUID(), name: "Peer", host: "10.0.0.1", port: 51888)

    @Test("emits offer, chunks, then finish with correct chunk headers")
    func requestSequence() async throws {
        let key = SymmetricKey(size: .bits256)
        let transport = RecordingTransport()
        let sender = try await makeSender(peerId: peer.id, key: key, transport: transport)
        // 9 MiB -> 3 chunks (4 + 4 + 1 MiB).
        let url = try makeFile(bytes: 9 * 1024 * 1024)

        try await sender.sendFile(at: url, to: peer)

        let paths = transport.requests.map(\.path)
        #expect(paths == ["/v1/file/offer", "/v1/file/chunk", "/v1/file/chunk", "/v1/file/chunk", "/v1/file/finish"])

        let chunkRequests = transport.requests.filter { $0.path == "/v1/file/chunk" }
        #expect(chunkRequests.map { $0.headers["x-chunk-index"] } == ["0", "1", "2"])
        let ids = Set(chunkRequests.compactMap { $0.headers["x-transfer-id"] })
        #expect(ids.count == 1)
        #expect(chunkRequests.allSatisfy { $0.headers["content-type"] == "application/octet-stream" })
    }

    @Test("progress is monotonic and ends at 1.0")
    func monotonicProgress() async throws {
        let transport = RecordingTransport()
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        let url = try makeFile(bytes: 9 * 1024 * 1024)
        let collector = Collector()

        try await sender.sendFile(at: url, to: peer, progress: { collector.record($0) })

        let values = collector.snapshot
        #expect(values == values.sorted())
        #expect(values.last == 1.0)
    }

    @Test("cancellation mid-stream aborts and issues /v1/file/cancel")
    func cancelMidStream() async throws {
        let transport = RecordingTransport()
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        let url = try makeFile(bytes: 9 * 1024 * 1024)
        // Allow the first isCancelled poll to pass, cancel on the second.
        let counter = Counter(cancelAt: 1)

        await #expect(throws: FileSendError.cancelled) {
            try await sender.sendFile(at: url, to: peer, isCancelled: { counter.poll() })
        }
        #expect(transport.requests.last?.path == "/v1/file/cancel")
    }

    @Test("a non-200 chunk response aborts and issues cancel")
    func nonOKChunkAborts() async throws {
        let transport = RecordingTransport()
        transport.statusForPath["/v1/file/chunk"] = 500
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        let url = try makeFile(bytes: 1024)

        await #expect(throws: FileSendError.self) {
            try await sender.sendFile(at: url, to: peer)
        }
        #expect(transport.requests.map(\.path).contains("/v1/file/cancel"))
    }

    @Test("finish waits for the receiver's hash: its timeout scales with file size (4 GB -> 205 s)")
    func finishUsesExtendedTimeoutForLargeFile() async throws {
        #expect(FileTransferConstants.finishTimeout(fileSize: 4 * 1024 * 1024 * 1024) == 205)
        #expect(FileTransferConstants.finishTimeout(fileSize: 0) == 30)
        #expect(FileTransferConstants.finishTimeout(fileSize: 30 * 20 * 1024 * 1024 + 1) == 31)
        #expect(FileTransferConstants.finishTimeout(fileSize: 1 << 40) == 600)

        let transport = RecordingTransport()
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        let size = 9 * 1024 * 1024
        try await sender.sendFile(at: try makeFile(bytes: size), to: peer)

        #expect(transport.timeouts(for: "/v1/file/finish") == [FileTransferConstants.finishTimeout(fileSize: Int64(size))])
        #expect(transport.timeouts(for: "/v1/file/offer") == [PeerTransportDefaults.requestTimeout])
        #expect(transport.timeouts(for: "/v1/file/chunk") == Array(repeating: PeerTransportDefaults.requestTimeout, count: 3))
    }

    @Test("a finish that times out is reported unconfirmed and sends no cancel (Review Focus 4)")
    func senderDoesNotCancelAfterFinishTimeout() async throws {
        let transport = RecordingTransport()
        transport.errorForPath["/v1/file/finish"] = URLError(.timedOut)
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)

        let outcome = try await sender.sendFile(at: try makeFile(bytes: 1024), to: peer)

        #expect(outcome == .unconfirmed)
        #expect(transport.requests.map(\.path) == ["/v1/file/offer", "/v1/file/chunk", "/v1/file/finish"])
    }

    @Test("a confirmed finish is reported delivered")
    func confirmedFinishIsDelivered() async throws {
        let transport = RecordingTransport()
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        #expect(try await sender.sendFile(at: try makeFile(bytes: 16), to: peer) == .delivered)
    }

    @Test("a non-200 offer aborts before any chunk or cancel")
    func nonOKOfferAborts() async throws {
        let transport = RecordingTransport()
        transport.statusForPath["/v1/file/offer"] = 401
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        let url = try makeFile(bytes: 1024)

        await #expect(throws: FileSendError.self) {
            try await sender.sendFile(at: url, to: peer)
        }
        #expect(transport.requests.map(\.path) == ["/v1/file/offer"])
    }

    @Test("refuses to send to a peer that advertises an older protocol")
    func refusesOutdatedPeer() async throws {
        let transport = RecordingTransport()
        let outdated = Peer(id: peer.id, name: "Peer", host: "10.0.0.1", port: 51888, protocolVersion: 1)
        let sender = try await makeSender(peerId: outdated.id, key: SymmetricKey(size: .bits256), transport: transport)
        await #expect(throws: FileSendError.peerNeedsUpdate) {
            try await sender.sendFile(at: try makeFile(bytes: 16), to: outdated)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("a 426 answer surfaces as peerNeedsUpdate with an update-the-other-device message")
    func upgradeRequiredSurfacesAsNeedsUpdate() async throws {
        let transport = RecordingTransport()
        transport.statusForPath["/v1/file/offer"] = 426
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        do {
            try await sender.sendFile(at: try makeFile(bytes: 16), to: peer)
            Issue.record("expected peerNeedsUpdate")
        } catch let error as FileSendError {
            #expect(error == .peerNeedsUpdate)
            #expect(error.localizedDescription == ProtocolMismatch.updateOtherDeviceMessage)
        }
    }

    @Test("sending to an unpaired peer throws notPaired")
    func unpairedThrows() async throws {
        let transport = RecordingTransport()
        // Sender's store only knows `peer.id`; send to a different peer.
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        let stranger = Peer(id: UUID(), name: "Stranger", host: "10.0.0.9", port: 51888)
        let url = try makeFile(bytes: 16)

        await #expect(throws: FileSendError.notPaired) {
            try await sender.sendFile(at: url, to: stranger)
        }
    }

    @Test("loopback e2e: 10 MiB file arrives hash-verified through the real codec")
    func loopbackEndToEnd() async throws {
        let senderId = UUID()
        let receiverId = UUID()
        let key = SymmetricKey(size: .bits256)
        // Each side's store knows the other side under the shared key.
        let senderStore = try await makePairedStore(peerId: receiverId, key: key)
        let receiverStore = try await makePairedStore(peerId: senderId, key: key)
        let destinationDir = try temporaryDirectory()
        let receiver = FileReceiver(
            pairedStore: receiverStore,
            localDeviceId: receiverId,
            transfersDirectory: try temporaryDirectory().appendingPathComponent("Transfers"),
            destinationProvider: { destinationDir }
        )
        let transport = LoopbackTransport(receiver: receiver)

        let sender = FileSender(identity: DeviceIdentity(id: senderId, name: "Mac"), pairedStore: senderStore, transport: transport)
        let sourceURL = try temporaryDirectory().appendingPathComponent("big.bin")
        let data = Data((0..<(10 * 1024 * 1024 + 123)).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: sourceURL)

        let peer = Peer(id: receiverId, name: "Peer", host: "127.0.0.1", port: 51888)
        try await sender.sendFile(at: sourceURL, to: peer)

        let dest = destinationDir.appendingPathComponent("big.bin")
        #expect(try ContentHasher.fileHash(contentsOf: dest) == ContentHasher.fileHash(data))
    }
    // MARK: - Clock skew (Review Focus 1)

    @Test("a stale answer surfaces as clockOutOfSync naming the device")
    func staleAnswerSurfacesAsClockOutOfSync() async throws {
        let transport = RecordingTransport()
        transport.statusForPath["/v1/file/offer"] = 400
        transport.bodyForPath["/v1/file/offer"] = Data(#"{"status":"stale"}"#.utf8)
        let sender = try await makeSender(peerId: peer.id, key: SymmetricKey(size: .bits256), transport: transport)
        do {
            try await sender.sendFile(at: try makeFile(bytes: 16), to: peer)
            Issue.record("expected clockOutOfSync")
        } catch let error as FileSendError {
            #expect(error == .clockOutOfSync(deviceName: "Peer"))
            #expect(error.localizedDescription == "Clock out of sync with Peer.")
        }
    }

    private func loopbackSend(receiverClockOffset: TimeInterval) async throws -> (URL, Data) {
        let senderId = UUID()
        let receiverId = UUID()
        let key = SymmetricKey(size: .bits256)
        let senderStore = try await makePairedStore(peerId: receiverId, key: key)
        let receiverStore = try await makePairedStore(peerId: senderId, key: key)
        let destinationDir = try temporaryDirectory()
        let receiver = FileReceiver(
            pairedStore: receiverStore,
            localDeviceId: receiverId,
            transfersDirectory: try temporaryDirectory().appendingPathComponent("Transfers"),
            destinationProvider: { destinationDir },
            replayGuard: ReplayGuard(now: { Date().addingTimeInterval(receiverClockOffset) })
        )
        let sender = FileSender(identity: DeviceIdentity(id: senderId, name: "Mac"), pairedStore: senderStore, transport: LoopbackTransport(receiver: receiver))
        let data = Data((0..<100).map { UInt8($0) })
        let sourceURL = try temporaryDirectory().appendingPathComponent("skew.bin")
        try data.write(to: sourceURL)
        try await sender.sendFile(at: sourceURL, to: Peer(id: receiverId, name: "Phone", host: "127.0.0.1", port: 51888))
        return (destinationDir.appendingPathComponent("skew.bin"), data)
    }

    @Test("a receiver whose clock is 4 minutes off still receives the file")
    func fourMinuteSkewStillSyncs() async throws {
        let (dest, data) = try await loopbackSend(receiverClockOffset: 240)
        #expect(try Data(contentsOf: dest) == data)
    }

    @Test("a receiver whose clock is 20 minutes off reports the clock as out of sync")
    func twentyMinuteSkewIsClockOutOfSync() async throws {
        await #expect(throws: FileSendError.clockOutOfSync(deviceName: "Phone")) {
            _ = try await loopbackSend(receiverClockOffset: -1_200)
        }
    }
}
