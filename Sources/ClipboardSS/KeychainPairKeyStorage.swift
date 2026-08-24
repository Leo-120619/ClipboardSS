import Foundation
import CryptoKit
import Security
import ClipboardCore

public final class KeychainPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    public init() {}
    
    private func queryDict(for deviceId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.ClipboardSS.pairKeys",
            kSecAttrAccount as String: deviceId.uuidString
        ]
    }
    
    public func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        
        var query = queryDict(for: deviceId)
        SecItemDelete(query as CFDictionary)
        
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: "KeychainPairKeyStorage", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to store key in Keychain"])
        }
    }
    
    public func getKey(for deviceId: UUID) throws -> SymmetricKey? {
        var query = queryDict(for: deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecItemNotFound {
            return nil
        } else if status != errSecSuccess {
            throw NSError(domain: "KeychainPairKeyStorage", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to read key from Keychain"])
        }
        
        guard let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }
    
    public func deleteKey(for deviceId: UUID) throws {
        let query = queryDict(for: deviceId)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "KeychainPairKeyStorage", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to delete key from Keychain"])
        }
    }
}
