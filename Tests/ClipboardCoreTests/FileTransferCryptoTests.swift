import Foundation
import CryptoKit
import Testing
@testable import ClipboardCore

@Suite("FileTransferCrypto")
struct FileTransferCryptoTests {
    // Pinned vectors — must match docs/wire-protocol.md byte-for-byte.
    private let pairKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    private let transferId = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
    private let sample = Data([1, 2, 3])

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("fileHash of [1,2,3] matches the pinned vector")
    func fileHashVector() {
        #expect(ContentHasher.fileHash(sample) == "53d35d037113cb046848c134d774023f716d41879185bb35b942a0472bcd70fe")
    }

    @Test("deriveFileKey matches the pinned vector")
    func fileKeyVector() {
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: pairKey, transferId: transferId)
        let keyHex = fileKey.withUnsafeBytes { hex(Data($0)) }
        #expect(keyHex == "2b3f780b885ee8149fe062a00b2bb4ecc9b4326c058ad858b23009f3397a4554")
    }

    @Test("chunk nonces are 4 zero bytes plus big-endian index")
    func nonceVectors() {
        #expect(hex(FileTransferCrypto.nonce(forChunk: 0)) == "000000000000000000000000")
        #expect(hex(FileTransferCrypto.nonce(forChunk: 1)) == "000000000000000000000001")
    }

    @Test("sealed chunk bodies match the pinned vectors")
    func chunkVectors() throws {
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: pairKey, transferId: transferId)
        let chunk0 = try FileTransferCrypto.sealChunk(sample, fileKey: fileKey, index: 0)
        let chunk1 = try FileTransferCrypto.sealChunk(sample, fileKey: fileKey, index: 1)
        #expect(hex(chunk0) == "878b3fd3c6494ba0be8976ec7543362243af08")
        #expect(hex(chunk1) == "fc5bf0de6da51d44d7e16d35ec05ed598dd1cf")
    }

    @Test("openChunk round-trips a sealed chunk")
    func roundTrip() throws {
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: pairKey, transferId: transferId)
        let sealed = try FileTransferCrypto.sealChunk(sample, fileKey: fileKey, index: 7)
        let opened = try FileTransferCrypto.openChunk(sealed, fileKey: fileKey, index: 7)
        #expect(opened == sample)
    }

    @Test("openChunk fails when the index (nonce) is wrong")
    func wrongIndexFails() throws {
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: pairKey, transferId: transferId)
        let sealed = try FileTransferCrypto.sealChunk(sample, fileKey: fileKey, index: 0)
        #expect(throws: FileTransferCryptoError.self) {
            _ = try FileTransferCrypto.openChunk(sealed, fileKey: fileKey, index: 1)
        }
    }

    @Test("openChunk fails when the key is wrong")
    func wrongKeyFails() throws {
        let fileKey = FileTransferCrypto.deriveFileKey(pairKey: pairKey, transferId: transferId)
        let sealed = try FileTransferCrypto.sealChunk(sample, fileKey: fileKey, index: 0)
        let otherKey = FileTransferCrypto.deriveFileKey(pairKey: pairKey, transferId: "00000000-0000-0000-0000-000000000000")
        #expect(throws: FileTransferCryptoError.self) {
            _ = try FileTransferCrypto.openChunk(sealed, fileKey: otherKey, index: 0)
        }
    }

    @Test("streaming fileHash matches the in-memory hash")
    func streamingHashMatchesInMemory() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("blob.bin")
        let data = Data((0..<(3 * 1024 * 1024 + 7)).map { UInt8($0 % 256) })
        try data.write(to: url)
        #expect(try ContentHasher.fileHash(contentsOf: url) == ContentHasher.fileHash(data))
    }
}
