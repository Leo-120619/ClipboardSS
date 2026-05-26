import CryptoKit
import Foundation

public enum ContentHasher {
    public static func textHash(_ text: String) -> String {
        hash(Data(text.utf8), namespace: "text")
    }

    public static func imageHash(_ data: Data) -> String {
        hash(data, namespace: "image")
    }

    private static func hash(_ data: Data, namespace: String) -> String {
        var namespaced = Data(namespace.utf8)
        namespaced.append(0)
        namespaced.append(data)
        let digest = SHA256.hash(data: namespaced)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
