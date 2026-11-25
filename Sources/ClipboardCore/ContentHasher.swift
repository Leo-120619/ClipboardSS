import CryptoKit
import Foundation

public enum ContentHasher {
    public static func textHash(_ text: String) -> String {
        hash(Data(text.utf8), namespace: "text")
    }

    public static func imageHash(_ data: Data) -> String {
        hash(data, namespace: "image")
    }

    /// In-memory file hash, `SHA256("file" + 0x00 + data)`. Used by the pinned test vectors.
    public static func fileHash(_ data: Data) -> String {
        hash(data, namespace: "file")
    }

    /// Streaming file hash — reads the file in 1 MiB slices so it never loads the whole
    /// file into memory. Produces the same value as `fileHash(_:)` over the file's bytes.
    public static func fileHash(contentsOf url: URL) throws -> String {
        var hasher = SHA256()
        var prefix = Data("file".utf8)
        prefix.append(0)
        hasher.update(data: prefix)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// Hashes `namespace + 0x00 + data` incrementally, without first copying `data`
    /// (a copied image can be tens of MB) into a new buffer.
    private static func hash(_ data: Data, namespace: String) -> String {
        var hasher = SHA256()
        var prefix = Data(namespace.utf8)
        prefix.append(0)
        hasher.update(data: prefix)
        hasher.update(data: data)
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
