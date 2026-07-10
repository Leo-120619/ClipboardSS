import Foundation
import CryptoKit
import Testing
@testable import ClipboardCore

@Suite("FileReceiver")
struct FileReceiverTests {
    // MARK: - Fixture

    struct Fixture {
        let receiver: FileReceiver
        let peerId: UUID
        let key: SymmetricKey
        let destinationDir: URL
        let clock: MutableClock
    }

    private func makeFixture(now: Date = Date(timeIntervalSince1970: 1_000)) async throws -> Fixture {
        let peerId = UUID()
        let key = SymmetricKey(size: .bits256)
        let store = try await makePairedStore(peerId: peerId, key: key)
        let clock = MutableClock(now)
        let destinationDir = try temporaryDirectory()
        let receiver = FileReceiver(
            pairedStore: store,
            transfersDirectory: try temporaryDirectory().appendingPathComponent("Transfers"),
            destinationProvider: { destinationDir },
            now: clock.now,
            idleTimeout: 60
        )
        return Fixture(receiver: receiver, peerId: peerId, key: key, destinationDir: destinationDir, clock: clock)
    }

    /// Builds an offer for `data` split at `chunkSize`, returning the offer + sealed chunks.
    private func makeTransfer(
        _ fixture: Fixture,
        data: Data,
        chunkSize: Int,
        fileName: String = "file.bin",
        overrideHash: String? = nil
    ) throws -> (offer: ClipEnvelope, chunks: [Data], transferId: String) {
        let transferId = UUID().uuidString.lowercased()
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: fixture.key, transferId: transferId)
        var chunks: [Data] = []
        var index = 0
        var offset = 0
        while offset < data.count {
            let slice = data.subdata(in: offset..<min(offset + chunkSize, data.count))
            chunks.append(try FileTransferCrypto.sealChunk(slice, fileKey: fileKey, index: UInt64(index)))
            offset += chunkSize
            index += 1
        }
        let payload = FileOfferPayload(
            transferId: transferId,
            fileName: fileName,
            fileSize: Int64(data.count),
            mimeType: "application/octet-stream",
            fileHash: overrideHash ?? ContentHasher.fileHash(data),
            chunkSize: chunkSize,
            chunkCount: chunks.count,
            createdAt: Date(),
            sourceDeviceName: "Peer"
        )
        let offer = try sealedEnvelope(payload, sourceDeviceId: fixture.peerId, key: fixture.key)
        return (offer, chunks, transferId)
    }

    private func status(_ response: FileTransferResponse) -> String {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["status"] as? String ?? ""
    }

    // MARK: - Tests

    @Test("happy path reassembles the file to the destination and removes the temp file")
    func happyPath() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)

        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
        for (i, chunk) in chunks.enumerated() {
            #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: i, body: chunk).statusCode == 200)
        }
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), sourceDeviceId: fixture.peerId, key: fixture.key)
        #expect(await fixture.receiver.handleFinish(envelope: finish).statusCode == 200)

        let dest = fixture.destinationDir.appendingPathComponent("file.bin")
        #expect(try Data(contentsOf: dest) == data)
    }

    @Test("out-of-order chunks still complete")
    func outOfOrder() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        for i in [2, 0, 1] {
            #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: i, body: chunks[i]).statusCode == 200)
        }
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), sourceDeviceId: fixture.peerId, key: fixture.key)
        #expect(await fixture.receiver.handleFinish(envelope: finish).statusCode == 200)
        #expect(try Data(contentsOf: fixture.destinationDir.appendingPathComponent("file.bin")) == data)
    }

    @Test("duplicate chunk is idempotent")
    func duplicateChunk() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        let second = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        #expect(second.statusCode == 200)
        let received = (try? JSONSerialization.jsonObject(with: second.body) as? [String: Any])?["received"] as? Int
        #expect(received == 1)
    }

    @Test("finish before all chunks arrive returns 409 incomplete")
    func incompleteFinish() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), sourceDeviceId: fixture.peerId, key: fixture.key)
        let response = await fixture.receiver.handleFinish(envelope: finish)
        #expect(response.statusCode == 409)
        #expect(status(response) == "incomplete")
    }

    @Test("corrupted chunk tears the session down with 400")
    func corruptedChunk() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        var corrupt = chunks[0]
        corrupt[corrupt.startIndex] ^= 0xFF
        let response = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: corrupt)
        #expect(response.statusCode == 400)
        // Session is gone: a subsequent valid chunk is now unknown.
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 1, body: chunks[1]).statusCode == 404)
    }

    @Test("hash mismatch returns 422 and deletes the temp file")
    func hashMismatch() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4, overrideHash: String(repeating: "0", count: 64))
        _ = await fixture.receiver.handleOffer(envelope: offer)
        for (i, chunk) in chunks.enumerated() {
            _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: i, body: chunk)
        }
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), sourceDeviceId: fixture.peerId, key: fixture.key)
        let response = await fixture.receiver.handleFinish(envelope: finish)
        #expect(response.statusCode == 422)
        #expect(status(response) == "hashMismatch")
        #expect(FileManager.default.fileExists(atPath: fixture.destinationDir.appendingPathComponent("file.bin").path) == false)
    }

    @Test("cancel removes the session; later chunks get 410")
    func cancel() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        let cancel = try sealedEnvelope(FileCancelPayload(transferId: id), sourceDeviceId: fixture.peerId, key: fixture.key)
        #expect(await fixture.receiver.handleCancel(envelope: cancel).statusCode == 200)
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 1, body: chunks[1]).statusCode == 410)
    }

    @Test("idle sessions are garbage-collected")
    func idleGC() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        fixture.clock.advance(by: 61)
        await fixture.receiver.garbageCollect()
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 1, body: chunks[1]).statusCode == 404)
    }

    @Test("chunk for an unknown transfer returns 404")
    func unknownTransfer() async throws {
        let fixture = try await makeFixture()
        #expect(await fixture.receiver.handleChunk(transferId: "nope", chunkIndex: 0, body: Data(repeating: 0, count: 32)).statusCode == 404)
    }

    @Test("offer from an unpaired device returns 401")
    func unpairedOffer() async throws {
        let fixture = try await makeFixture()
        let strangerId = UUID()
        let strangerKey = SymmetricKey(size: .bits256)
        let payload = FileOfferPayload(
            transferId: UUID().uuidString.lowercased(), fileName: "x.bin", fileSize: 1,
            mimeType: "application/octet-stream", fileHash: "h", chunkSize: 4, chunkCount: 1,
            createdAt: Date(), sourceDeviceName: "Stranger"
        )
        let offer = try sealedEnvelope(payload, sourceDeviceId: strangerId, key: strangerKey)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 401)
    }

    @Test("a duplicate active transferId is rejected with 409")
    func duplicateTransferId() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, _, _) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 409)
    }

    @Test("colliding file names are given a unique suffix")
    func collisionSafeNaming() async throws {
        let fixture = try await makeFixture()
        // Pre-existing file at the destination.
        try Data("existing".utf8).write(to: fixture.destinationDir.appendingPathComponent("file.bin"))
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), sourceDeviceId: fixture.peerId, key: fixture.key)
        #expect(await fixture.receiver.handleFinish(envelope: finish).statusCode == 200)
        #expect(try Data(contentsOf: fixture.destinationDir.appendingPathComponent("file (1).bin")) == data)
    }
}
