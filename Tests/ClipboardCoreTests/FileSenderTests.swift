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
        let peerId = UUID()
        let key = SymmetricKey(size: .bits256)
        let store = try await makePairedStore(peerId: peerId, key: key)
        let destinationDir = try temporaryDirectory()
        let receiver = FileReceiver(
            pairedStore: store,
            transfersDirectory: try temporaryDirectory().appendingPathComponent("Transfers"),
            destinationProvider: { destinationDir }
        )
        let transport = LoopbackTransport(receiver: receiver)

        // Sender's identity must be the paired peer id so the receiver can find the key.
        let sender = FileSender(identity: DeviceIdentity(id: peerId, name: "Peer"), pairedStore: store, transport: transport)
        let sourceURL = try temporaryDirectory().appendingPathComponent("big.bin")
        let data = Data((0..<(10 * 1024 * 1024 + 123)).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: sourceURL)

        let peer = Peer(id: peerId, name: "Peer", host: "127.0.0.1", port: 51888)
        try await sender.sendFile(at: sourceURL, to: peer)

        let dest = destinationDir.appendingPathComponent("big.bin")
        #expect(try ContentHasher.fileHash(contentsOf: dest) == ContentHasher.fileHash(data))
    }
}
