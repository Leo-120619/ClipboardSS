import Foundation
import CryptoKit

public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var host: String?
    public var connected: Bool

    public init(id: UUID, name: String, host: String? = nil, connected: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.connected = connected
    }

    private enum CodingKeys: String, CodingKey { case id, name, host, connected }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? true
    }
}

public protocol PairKeyStorage: Sendable {
    func storeKey(_ key: SymmetricKey, for deviceId: UUID) throws
    func getKey(for deviceId: UUID) throws -> SymmetricKey?
    func deleteKey(for deviceId: UUID) throws
}

public actor PairedDeviceStore {
    private let storageURL: URL
    private let keyStorage: PairKeyStorage
    private let fileManager: FileManager
    
    public private(set) var devices: [PairedDevice]

    public init(storageURL: URL, keyStorage: PairKeyStorage, fileManager: FileManager = .default) throws {
        self.storageURL = storageURL
        self.keyStorage = keyStorage
        self.fileManager = fileManager
        
        if fileManager.fileExists(atPath: storageURL.path) {
            let data = try Data(contentsOf: storageURL)
            self.devices = try JSONDecoder().decode([PairedDevice].self, from: data)
        } else {
            self.devices = []
        }
    }
    
    public func addDevice(_ device: PairedDevice, key: SymmetricKey) throws {
        try keyStorage.storeKey(key, for: device.id)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            // Re-pairing refreshes identity data but must not silently resume a paused device.
            var refreshed = device
            refreshed.connected = devices[index].connected
            devices[index] = refreshed
        } else {
            devices.append(device)
        }
        try save()
    }
    
    public func removeDevice(id: UUID) throws {
        try keyStorage.deleteKey(for: id)
        devices.removeAll { $0.id == id }
        try save()
    }
    
    public func getKey(for deviceId: UUID) throws -> SymmetricKey? {
        try keyStorage.getKey(for: deviceId)
    }

    public func isConnected(_ deviceId: UUID) -> Bool {
        devices.first(where: { $0.id == deviceId })?.connected ?? false
    }

    public func setConnected(_ deviceId: UUID, _ connected: Bool) throws {
        guard let index = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[index].connected = connected
        try save()
    }
    
    private func save() throws {
        let data = try JSONEncoder().encode(devices)
        try data.write(to: storageURL, options: .atomic)
    }
}
