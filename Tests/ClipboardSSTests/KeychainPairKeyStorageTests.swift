import CryptoKit
import Foundation
import Security
import Testing
@testable import ClipboardSS

@Suite("Keychain pair key storage")
struct KeychainPairKeyStorageTests {
    final class FakeKeychain: PairKeychain, @unchecked Sendable {
        var protected: [UUID: Data] = [:]
        var legacy: [UUID: Data] = [:]
        var prompts = 0
        var promptResult: OSStatus = errSecSuccess

        func protectedAccounts() throws -> Set<UUID> { Set(protected.keys) }
        func loadAllProtected(reason: String) throws -> [UUID: Data] {
            guard !protected.isEmpty else { return [:] }
            prompts += 1
            guard promptResult == errSecSuccess else { throw PairKeychainError.status(promptResult) }
            return protected
        }
        func addProtected(_ data: Data, account: UUID) throws {
            guard protected[account] == nil else { throw PairKeychainError.status(errSecDuplicateItem) }
            protected[account] = data
        }
        func deleteProtected(account: UUID) throws { protected[account] = nil }
        func legacyAccounts() throws -> [UUID] { Array(legacy.keys) }
        func legacyData(account: UUID) throws -> Data? { legacy[account] }
        func deleteLegacy(account: UUID) throws { legacy[account] = nil }
    }

    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    private func bytes(_ key: SymmetricKey?) -> Data? {
        key.map { $0.withUnsafeBytes { Data($0) } }
    }

    @Test("all keys unlock with one prompt and stay cached")
    func singlePrompt() throws {
        let keychain = FakeKeychain()
        let a = UUID(), b = UUID()
        keychain.protected = [a: Data(repeating: 1, count: 32), b: Data(repeating: 2, count: 32)]
        let storage = KeychainPairKeyStorage(keychain: keychain)

        #expect(bytes(try storage.getKey(for: a)) == Data(repeating: 1, count: 32))
        #expect(bytes(try storage.getKey(for: b)) == Data(repeating: 2, count: 32))
        #expect(try storage.getKey(for: UUID()) == nil)
        #expect(keychain.prompts == 1)
    }

    @Test("no paired devices means no prompt")
    func emptyNoPrompt() throws {
        let keychain = FakeKeychain()
        let storage = KeychainPairKeyStorage(keychain: keychain)
        #expect(try storage.getKey(for: UUID()) == nil)
        #expect(keychain.prompts == 0)
    }

    @Test("legacy login-keychain keys move to the protected keychain")
    func migratesLegacy() throws {
        let keychain = FakeKeychain()
        let old = UUID(), both = UUID()
        keychain.legacy = [old: Data(repeating: 7, count: 32), both: Data(repeating: 8, count: 32)]
        keychain.protected = [both: Data(repeating: 9, count: 32)]
        let storage = KeychainPairKeyStorage(keychain: keychain)

        #expect(bytes(try storage.getKey(for: old)) == Data(repeating: 7, count: 32))
        // An existing protected key wins over a stale legacy copy.
        #expect(bytes(try storage.getKey(for: both)) == Data(repeating: 9, count: 32))
        #expect(keychain.legacy.isEmpty)
        #expect(keychain.protected[old] == Data(repeating: 7, count: 32))
    }

    @Test("a cancelled prompt is not repeated until the cooldown passes")
    func cancelCooldown() throws {
        let keychain = FakeKeychain()
        let id = UUID()
        keychain.protected = [id: Data(repeating: 3, count: 32)]
        keychain.promptResult = errSecUserCanceled
        let clock = Clock()
        let storage = KeychainPairKeyStorage(keychain: keychain, now: { clock.date })

        #expect(throws: PairKeychainError.status(errSecUserCanceled)) { try storage.getKey(for: id) }
        #expect(throws: PairKeychainError.authenticationDeferred) { try storage.getKey(for: id) }
        #expect(keychain.prompts == 1)

        keychain.promptResult = errSecSuccess
        clock.date += KeychainPairKeyStorage.promptCooldown + 1
        #expect(bytes(try storage.getKey(for: id)) == Data(repeating: 3, count: 32))
        #expect(keychain.prompts == 2)
    }

    @Test("store and delete keep the unlocked cache in sync")
    func storeAndDelete() throws {
        let keychain = FakeKeychain()
        let existing = UUID(), added = UUID()
        keychain.protected = [existing: Data(repeating: 1, count: 32)]
        keychain.legacy = [added: Data(repeating: 5, count: 32)]
        let storage = KeychainPairKeyStorage(keychain: keychain)
        _ = try storage.getKey(for: existing)

        let newKey = SymmetricKey(data: Data(repeating: 4, count: 32))
        try storage.storeKey(newKey, for: added)
        #expect(bytes(try storage.getKey(for: added)) == Data(repeating: 4, count: 32))
        #expect(keychain.legacy[added] == nil)

        try storage.deleteKey(for: existing)
        #expect(try storage.getKey(for: existing) == nil)
        #expect(keychain.protected[existing] == nil)
        #expect(keychain.prompts == 1)
    }
}
