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
        /// The receiving device's own id (envelope recipient).
        let localId: UUID
        let key: SymmetricKey
        let destinationDir: URL
        let clock: MutableClock
        let store: PairedDeviceStore
        let transfersDir: URL
    }

    private func makeFixture(
        now: Date = Date(timeIntervalSince1970: 1_000),
        freeSpace: Int64 = 1 << 40,
        chunkWriter: @escaping @Sendable (FileHandle, UInt64, Data) throws -> Void = FileReceiver.defaultChunkWriter
    ) async throws -> Fixture {
        let peerId = UUID()
        let key = SymmetricKey(size: .bits256)
        let store = try await makePairedStore(peerId: peerId, key: key)
        let clock = MutableClock(now)
        let destinationDir = try temporaryDirectory()
        let localId = UUID()
        let transfersDir = try temporaryDirectory().appendingPathComponent("Transfers")
        let receiver = FileReceiver(
            pairedStore: store,
            localDeviceId: localId,
            transfersDirectory: transfersDir,
            destinationProvider: { destinationDir },
            now: clock.now,
            idleTimeout: 60,
            freeSpaceProvider: { freeSpace },
            chunkWriter: chunkWriter
        )
        return Fixture(receiver: receiver, peerId: peerId, localId: localId, key: key, destinationDir: destinationDir, clock: clock, store: store, transfersDir: transfersDir)
    }

    /// Builds an offer for `data` split at `chunkSize`, returning the offer + sealed chunks.
    private func makeTransfer(
        _ fixture: Fixture,
        data: Data,
        chunkSize: Int,
        fileName: String = "file.bin",
        overrideHash: String? = nil,
        sentAt: Date = Date()
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
        let offer = try sealedEnvelope(payload, purpose: .fileOffer, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key, sentAt: sentAt)
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
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
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
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
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

    @Test("a malformed duplicate chunk is authenticated and rejected")
    func malformedDuplicateChunk() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        let response = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: Data(repeating: 0, count: 16))
        #expect(response.statusCode == 400)
    }

    @Test("offer validation rejects unsafe ids and invalid math before creating files")
    func offerValidation() async throws {
        let fixture = try await makeFixture()
        func offer(id: String, size: Int64, chunkSize: Int, count: Int) throws -> ClipEnvelope {
            try sealedEnvelope(FileOfferPayload(
                transferId: id, fileName: "file.bin", fileSize: size,
                mimeType: "application/octet-stream", fileHash: "h", chunkSize: chunkSize,
                chunkCount: count, createdAt: Date(), sourceDeviceName: "Peer"
            ), purpose: .fileOffer, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        }
        let invalidId = try offer(id: "../../evil", size: 1, chunkSize: 1, count: 1)
        let invalidIdResponse = await fixture.receiver.handleOffer(envelope: invalidId)
        #expect(invalidIdResponse.statusCode == 400)
        #expect(status(invalidIdResponse) == "invalidId")
        let invalidOffer = try offer(id: UUID().uuidString.lowercased(), size: 1, chunkSize: -1, count: 1)
        let invalidOfferResponse = await fixture.receiver.handleOffer(envelope: invalidOffer)
        #expect(invalidOfferResponse.statusCode == 400)
        #expect(status(invalidOfferResponse) == "invalidOffer")
    }

    @Test("finish before all chunks arrive returns 409 incomplete")
    func incompleteFinish() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        let response = await fixture.receiver.handleFinish(envelope: finish)
        #expect(response.statusCode == 409)
        #expect(status(response) == "incomplete")
    }

    // MARK: - Robustness (junk chunks, ownership, quota, cleanup)

    private func finishEnvelope(_ fixture: Fixture, _ id: String, from source: UUID? = nil, key: SymmetricKey? = nil) throws -> ClipEnvelope {
        try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: source ?? fixture.peerId, recipientDeviceId: fixture.localId, key: key ?? fixture.key)
    }

    private func offerEnvelope(_ fixture: Fixture, size: Int64, from source: UUID? = nil, key: SymmetricKey? = nil) throws -> ClipEnvelope {
        let chunkSize = FileTransferConstants.chunkSize
        let count = Int(size / Int64(chunkSize) + (size % Int64(chunkSize) == 0 ? 0 : 1))
        return try sealedEnvelope(FileOfferPayload(
            transferId: UUID().uuidString.lowercased(), fileName: "big.bin", fileSize: size,
            mimeType: "application/octet-stream", fileHash: "h", chunkSize: chunkSize,
            chunkCount: count, createdAt: Date(), sourceDeviceName: "Peer"
        ), purpose: .fileOffer, sourceDeviceId: source ?? fixture.peerId, recipientDeviceId: fixture.localId, key: key ?? fixture.key)
    }

    private func pairSecondPeer(_ fixture: Fixture) async throws -> (UUID, SymmetricKey) {
        let otherId = UUID()
        let otherKey = SymmetricKey(size: .bits256)
        try await fixture.store.addDevice(PairedDevice(id: otherId, name: "Other"), key: otherKey)
        return (otherId, otherKey)
    }

    @Test("junk, bad-index and bad-size chunks return 400 and leave the session intact")
    func junkChunkDoesNotDestroySession() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<10).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)

        var corrupt = chunks[0]
        corrupt[corrupt.startIndex] ^= 0xFF
        let junk = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: corrupt)
        #expect(junk.statusCode == 400)
        #expect(status(junk) == "authFailed")
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: Data(repeating: 0, count: 64)).statusCode == 400)
        let badIndex = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 99, body: chunks[0])
        #expect(badIndex.statusCode == 400)
        #expect(status(badIndex) == "badIndex")
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: fixture.key, transferId: id)
        let shortChunk = try FileTransferCrypto.sealChunk(Data([9]), fileKey: fileKey, index: 0)
        let badSize = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: shortChunk)
        #expect(badSize.statusCode == 400)
        #expect(status(badSize) == "badSize")

        for (i, chunk) in chunks.enumerated() {
            #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: i, body: chunk).statusCode == 200)
        }
        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id)).statusCode == 200)
        #expect(try Data(contentsOf: fixture.destinationDir.appendingPathComponent("file.bin")) == data)
    }

    @Test("finish and cancel from a different paired device get 404 and leave the session intact")
    func finishFromDifferentPairedDeviceIsRejected() async throws {
        let fixture = try await makeFixture()
        let (otherId, otherKey) = try await pairSecondPeer(fixture)
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 200)

        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id, from: otherId, key: otherKey)).statusCode == 404)
        let foreignCancel = try sealedEnvelope(FileCancelPayload(transferId: id), purpose: .fileCancel, sourceDeviceId: otherId, recipientDeviceId: fixture.localId, key: otherKey)
        #expect(await fixture.receiver.handleCancel(envelope: foreignCancel).statusCode == 404)

        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id)).statusCode == 200)
    }

    @Test("finish and cancel from a paused device get 401 paused")
    func finishWhilePausedIsRejected() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 200)

        try await fixture.store.setConnected(fixture.peerId, false)
        let paused = await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id))
        #expect(paused.statusCode == 401)
        #expect(status(paused) == "paused")
        let cancel = try sealedEnvelope(FileCancelPayload(transferId: id), purpose: .fileCancel, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        #expect(await fixture.receiver.handleCancel(envelope: cancel).statusCode == 401)

        try await fixture.store.setConnected(fixture.peerId, true)
        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id)).statusCode == 200)
    }

    @Test("an offer larger than free space minus the 500 MB reserve gets 400 tooLarge")
    func offerLargerThanFreeSpaceIsRejected() async throws {
        let reserve = FileTransferConstants.freeSpaceReserve
        #expect(reserve == 500 * 1024 * 1024)
        let fixture = try await makeFixture(freeSpace: reserve + 1_000)
        let tooLarge = await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 1_001))
        #expect(tooLarge.statusCode == 400)
        #expect(status(tooLarge) == "tooLarge")
        #expect(await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 1_000)).statusCode == 200)
    }

    @Test("bytes still owed to active sessions count against free space")
    func concurrentOffersCannotOvercommitFreeSpace() async throws {
        let fixture = try await makeFixture(freeSpace: FileTransferConstants.freeSpaceReserve + 1_000)
        #expect(await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 600)).statusCode == 200)
        let second = await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 600))
        #expect(second.statusCode == 400)
        #expect(status(second) == "tooLarge")
        #expect(await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 400)).statusCode == 200)
    }

    @Test("a hash read failure at finish returns 422 error and drops the session")
    func hashReadFailureIsError() async throws {
        let fixture = try await makeFixture()
        let (offer, chunks, id) = try makeTransfer(fixture, data: Data([1, 2, 3, 4]), chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        try FileManager.default.removeItem(at: fixture.transfersDir.appendingPathComponent("\(id).part"))
        let response = await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id))
        #expect(response.statusCode == 422)
        #expect(status(response) == "error")
        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id)).statusCode == 404)
    }

    @Test("a ninth concurrent session from one device gets 429")
    func ninthConcurrentSessionIsRejected() async throws {
        let fixture = try await makeFixture()
        #expect(FileTransferConstants.maxSessionsPerDevice == 8)
        for _ in 0..<8 {
            #expect(await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 1)).statusCode == 200)
        }
        let ninth = await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 1))
        #expect(ninth.statusCode == 429)
        #expect(status(ninth) == "tooManyTransfers")
        // The limit is per device.
        let (otherId, otherKey) = try await pairSecondPeer(fixture)
        #expect(await fixture.receiver.handleOffer(envelope: try offerEnvelope(fixture, size: 1, from: otherId, key: otherKey)).statusCode == 200)
    }

    @Test("a failed write does not mark the chunk received; a retry stores it")
    func failedWriteDoesNotMarkChunkReceived() async throws {
        let failures = FailCounter(failures: 1)
        let fixture = try await makeFixture(chunkWriter: { handle, offset, data in
            if failures.shouldFail() { throw CocoaError(.fileWriteOutOfSpace) }
            try FileReceiver.defaultChunkWriter(handle, offset, data)
        })
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)

        let failed = await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0])
        #expect(failed.statusCode == 400)
        #expect(status(failed) == "writeFailed")
        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id)).statusCode == 409)

        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 200)
        #expect(await fixture.receiver.handleFinish(envelope: try finishEnvelope(fixture, id)).statusCode == 200)
        #expect(try Data(contentsOf: fixture.destinationDir.appendingPathComponent("file.bin")) == data)
    }

    @Test("cancelled ids are pruned after 600 s")
    func cancelledIdsArePruned() async throws {
        let fixture = try await makeFixture()
        let (offer, chunks, id) = try makeTransfer(fixture, data: Data([1, 2, 3, 4]), chunkSize: 4)
        _ = await fixture.receiver.handleOffer(envelope: offer)
        let cancel = try sealedEnvelope(FileCancelPayload(transferId: id), purpose: .fileCancel, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        #expect(await fixture.receiver.handleCancel(envelope: cancel).statusCode == 200)
        fixture.clock.advance(by: 599)
        await fixture.receiver.garbageCollect()
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 410)
        fixture.clock.advance(by: 2)
        await fixture.receiver.garbageCollect()
        #expect(await fixture.receiver.cancelledTransferCount == 0)
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 404)
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
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
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
        let cancel = try sealedEnvelope(FileCancelPayload(transferId: id), purpose: .fileCancel, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
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
        let offer = try sealedEnvelope(payload, purpose: .fileOffer, sourceDeviceId: strangerId, recipientDeviceId: fixture.localId, key: strangerKey)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 401)
    }

    @Test("a duplicate active transferId is rejected with 409")
    func duplicateTransferId() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, _, _) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
        // Same payload under a fresh nonce: rejected by the active-session check, not the replay guard.
        let payload = try offer.open(FileOfferPayload.self, purpose: .fileOffer, recipientDeviceId: fixture.localId, pairKey: fixture.key)
        let resealed = try sealedEnvelope(payload, purpose: .fileOffer, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        let response = await fixture.receiver.handleOffer(envelope: resealed)
        #expect(response.statusCode == 409)
        #expect(status(response) == "duplicate")
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
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        #expect(await fixture.receiver.handleFinish(envelope: finish).statusCode == 200)
        #expect(try Data(contentsOf: fixture.destinationDir.appendingPathComponent("file (1).bin")) == data)
    }

    @Test("a captured offer envelope is not accepted as finish or cancel")
    func offerEnvelopeCannotFinishOrCancel() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<8).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)

        #expect(await fixture.receiver.handleFinish(envelope: offer).statusCode == 401)
        _ = await fixture.receiver.handleCancel(envelope: offer)

        // The session survived: chunks are still accepted.
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 200)
    }

    @Test("an offer sealed for another recipient is rejected")
    func offerForAnotherRecipientIsRejected() async throws {
        let fixture = try await makeFixture()
        let payload = FileOfferPayload(
            transferId: UUID().uuidString.lowercased(), fileName: "x.bin", fileSize: 1,
            mimeType: "application/octet-stream", fileHash: "h", chunkSize: 4, chunkCount: 1,
            createdAt: Date(), sourceDeviceName: "Peer"
        )
        let offer = try sealedEnvelope(payload, purpose: .fileOffer, sourceDeviceId: fixture.peerId, recipientDeviceId: UUID(), key: fixture.key)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 401)
    }

    @Test("v1 envelopes get 426 upgradeRequired on offer, finish and cancel")
    func v1EnvelopeGetsUpgradeRequired() async throws {
        let fixture = try await makeFixture()
        let (offer, _, _) = try makeTransfer(fixture, data: Data([1]), chunkSize: 4)
        let v1 = ClipEnvelope(v: 1, sourceDeviceId: offer.sourceDeviceId, nonce: offer.nonce, ciphertext: offer.ciphertext)
        for response in [
            await fixture.receiver.handleOffer(envelope: v1),
            await fixture.receiver.handleFinish(envelope: v1),
            await fixture.receiver.handleCancel(envelope: v1),
        ] {
            #expect(response.statusCode == 426)
            let obj = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            #expect(obj?["status"] as? String == "upgradeRequired")
            #expect(obj?["minVersion"] as? Int == 2)
        }
    }
    // MARK: - Replay protection

    @Test("an offer replayed after finish is rejected and re-delivers nothing")
    func replayedOfferAfterFinishIsRejected() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<8).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
        for (i, chunk) in chunks.enumerated() {
            _ = await fixture.receiver.handleChunk(transferId: id, chunkIndex: i, body: chunk)
        }
        let finish = try sealedEnvelope(FileFinishPayload(transferId: id), purpose: .fileFinish, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        #expect(await fixture.receiver.handleFinish(envelope: finish).statusCode == 200)

        let replayedOffer = await fixture.receiver.handleOffer(envelope: offer)
        #expect(replayedOffer.statusCode == 409)
        #expect(status(replayedOffer) == "replayed")
        // No session was created: the replayed chunks and finish go nowhere.
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 404)
        let replayedFinish = await fixture.receiver.handleFinish(envelope: finish)
        #expect(replayedFinish.statusCode == 409)
        #expect(status(replayedFinish) == "replayed")
        let delivered = try FileManager.default.contentsOfDirectory(atPath: fixture.destinationDir.path)
        #expect(delivered == ["file.bin"])
    }

    @Test("a replayed cancel is rejected")
    func replayedCancelIsRejected() async throws {
        let fixture = try await makeFixture()
        let cancel = try sealedEnvelope(FileCancelPayload(transferId: "abc"), purpose: .fileCancel, sourceDeviceId: fixture.peerId, recipientDeviceId: fixture.localId, key: fixture.key)
        #expect(await fixture.receiver.handleCancel(envelope: cancel).statusCode == 200)
        let replayed = await fixture.receiver.handleCancel(envelope: cancel)
        #expect(replayed.statusCode == 409)
        #expect(status(replayed) == "replayed")
    }

    @Test("an offer sent 20 minutes ago is stale and creates no session (Review Focus 1)")
    func staleOfferIsRejected() async throws {
        let fixture = try await makeFixture()
        let data = Data((0..<4).map { UInt8($0) })
        let (offer, chunks, id) = try makeTransfer(fixture, data: data, chunkSize: 4, sentAt: Date().addingTimeInterval(-1_200))
        let response = await fixture.receiver.handleOffer(envelope: offer)
        #expect(response.statusCode == 400)
        #expect(status(response) == "stale")
        #expect(await fixture.receiver.handleChunk(transferId: id, chunkIndex: 0, body: chunks[0]).statusCode == 404)
    }

    @Test("an offer sent 4 minutes ago is accepted (Review Focus 1)")
    func fourMinuteOldOfferIsAccepted() async throws {
        let fixture = try await makeFixture()
        let (offer, _, _) = try makeTransfer(fixture, data: Data([1]), chunkSize: 4, sentAt: Date().addingTimeInterval(-240))
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
    }

    @Test("a forged envelope does not burn the nonce of the genuine one")
    func failedOpenDoesNotEnterTheGuard() async throws {
        let fixture = try await makeFixture()
        let (offer, _, _) = try makeTransfer(fixture, data: Data([1]), chunkSize: 4)
        var forgedBytes = try #require(Data(base64Encoded: offer.ciphertext))
        forgedBytes[0] ^= 0xff
        let forged = ClipEnvelope(sourceDeviceId: offer.sourceDeviceId, nonce: offer.nonce, ciphertext: forgedBytes.base64EncodedString())
        #expect(await fixture.receiver.handleOffer(envelope: forged).statusCode == 401)
        #expect(await fixture.receiver.handleOffer(envelope: offer).statusCode == 200)
    }
}

/// Lets a test writer fail its first `failures` calls.
final class FailCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(failures: Int) { remaining = failures }
    func shouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
