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
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ data: Data, namespace: String) -> String {
        var namespaced = Data(namespace.utf8)
        namespaced.append(0)
        namespaced.append(data)
        let digest = SHA256.hash(data: namespaced)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
