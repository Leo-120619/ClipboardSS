import Foundation
import CryptoKit
import LocalAuthentication
import Security
import ClipboardCore

/// Stores per-device pair keys in the data protection keychain behind Touch ID
/// (or the Mac's login password when Touch ID is unavailable).
///
/// Keys are read on every clip, file and liveness ping, so the storage unlocks
/// all of them with a single prompt and keeps them in memory for the rest of
/// the process. Keys left in the legacy login keychain by older builds are
/// moved over on first use.
public final class KeychainPairKeyStorage: PairKeyStorage, @unchecked Sendable {
    /// After the user cancels or fails the prompt, don't ask again for this long:
    /// liveness pings would otherwise re-prompt every few seconds.
    static let promptCooldown: TimeInterval = 120

    private let keychain: PairKeychain
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// nil until the keychain has been unlocked in this process.
    private var cache: [UUID: SymmetricKey]?
    private var promptBlockedUntil: Date?

    public convenience init() {
        self.init(keychain: SystemPairKeychain())
    }

    init(keychain: PairKeychain, now: @escaping @Sendable () -> Date = Date.init) {
        self.keychain = keychain
        self.now = now
    }

    public func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        lock.lock()
        defer { lock.unlock() }
        try keychain.deleteProtected(account: deviceId)
        try? keychain.deleteLegacy(account: deviceId)
        try keychain.addProtected(keyData, account: deviceId)
        cache?[deviceId] = key
    }

    public func getKey(for deviceId: UUID) throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache[deviceId] }
        let loaded = try unlockAll()
        cache = loaded
        return loaded[deviceId]
    }

    public func deleteKey(for deviceId: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try keychain.deleteProtected(account: deviceId)
        try? keychain.deleteLegacy(account: deviceId)
        cache?[deviceId] = nil
    }

    /// Caller holds `lock`.
    private func unlockAll() throws -> [UUID: SymmetricKey] {
        if let blockedUntil = promptBlockedUntil, now() < blockedUntil {
            throw PairKeychainError.authenticationDeferred
        }
        migrateLegacyItems()
        do {
            let items = try keychain.loadAllProtected(reason: "unlock the keys for your paired devices")
            promptBlockedUntil = nil
            return items.mapValues { SymmetricKey(data: $0) }
        } catch let error as PairKeychainError where error.isUserAuthenticationFailure {
            promptBlockedUntil = now().addingTimeInterval(Self.promptCooldown)
            throw error
        }
    }

    /// Copies keys from the legacy login keychain into the protected one. Adding
    /// a protected item needs no authentication; reading a legacy item may show
    /// the old keychain password prompt one last time.
    private func migrateLegacyItems() {
        guard let legacy = try? keychain.legacyAccounts(), !legacy.isEmpty else { return }
        let existing = (try? keychain.protectedAccounts()) ?? []
        for account in legacy {
            if !existing.contains(account) {
                guard let data = try? keychain.legacyData(account: account),
                      (try? keychain.addProtected(data, account: account)) != nil else { continue }
            }
            try? keychain.deleteLegacy(account: account)
        }
    }
}

enum PairKeychainError: Error, Equatable, LocalizedError {
    case status(OSStatus)
    case authenticationDeferred

    var isUserAuthenticationFailure: Bool {
        switch self {
        case .status(let status):
            return status == errSecUserCanceled || status == errSecAuthFailed
                || status == errSecInteractionNotAllowed
        case .authenticationDeferred:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .authenticationDeferred:
            return "Paired device keys are locked until you authenticate again."
        }
    }
}

/// The raw keychain operations, split out so the caching and migration logic can be tested.
protocol PairKeychain: Sendable {
    func protectedAccounts() throws -> Set<UUID>
    /// Reads every protected key, prompting for Touch ID / password at most once.
    func loadAllProtected(reason: String) throws -> [UUID: Data]
    func addProtected(_ data: Data, account: UUID) throws
    func deleteProtected(account: UUID) throws
    func legacyAccounts() throws -> [UUID]
    func legacyData(account: UUID) throws -> Data?
    func deleteLegacy(account: UUID) throws
}

struct SystemPairKeychain: PairKeychain {
    static let service = "com.local.ClipboardSS.pairKeys"

    private func base(dataProtection: Bool, account: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let account {
            query[kSecAttrAccount as String] = account.uuidString
        }
        return query
    }

    private func accounts(dataProtection: Bool) throws -> [UUID] {
        var query = base(dataProtection: dataProtection)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        if dataProtection {
            // Listing attributes never needs authentication; make sure it can't prompt.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PairKeychainError.status(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init) }
    }

    func protectedAccounts() throws -> Set<UUID> {
        Set(try accounts(dataProtection: true))
    }

    func loadAllProtected(reason: String) throws -> [UUID: Data] {
        guard !(try protectedAccounts()).isEmpty else { return [:] }

        // One evaluated context authorizes every item read below, so the user
        // sees a single Touch ID prompt for all paired devices.
        let context = LAContext()
        context.localizedReason = reason
        try evaluate(context, reason: reason)

        var query = base(dataProtection: true)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw PairKeychainError.status(status) }

        var keys: [UUID: Data] = [:]
        for item in result as? [[String: Any]] ?? [] {
            guard let account = (item[kSecAttrAccount as String] as? String).flatMap(UUID.init),
                  let data = item[kSecValueData as String] as? Data else { continue }
            keys[account] = data
        }
        return keys
    }

    private func evaluate(_ context: LAContext, reason: String) throws {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if !success { outcome = error ?? LAError(.authenticationFailed) }
            semaphore.signal()
        }
        semaphore.wait()
        guard let outcome else { return }
        switch (outcome as? LAError)?.code {
        case .userCancel?, .systemCancel?, .appCancel?:
            throw PairKeychainError.status(errSecUserCanceled)
        default:
            throw PairKeychainError.status(errSecAuthFailed)
        }
    }

    func addProtected(_ data: Data, account: UUID) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        var query = base(dataProtection: true, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairKeychainError.status(status) }
    }

    func deleteProtected(account: UUID) throws {
        try delete(base(dataProtection: true, account: account))
    }

    func legacyAccounts() throws -> [UUID] {
        try accounts(dataProtection: false)
    }

    func legacyData(account: UUID) throws -> Data? {
        var query = base(dataProtection: false, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PairKeychainError.status(status) }
        return result as? Data
    }

    func deleteLegacy(account: UUID) throws {
        try delete(base(dataProtection: false, account: account))
    }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairKeychainError.status(status)
        }
    }
}
