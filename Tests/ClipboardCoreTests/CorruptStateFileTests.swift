import CryptoKit
import Foundation
import Testing
@testable import ClipboardCore

@Suite("Corrupt state files")
struct CorruptStateFileTests {
    @Test("a corrupt clips.json is quarantined and the store starts empty")
    func corruptClipsFileIsQuarantinedAndStoreStartsEmpty() throws {
        let directory = try temporaryDirectory()
        let clipsURL = directory.appendingPathComponent("clips.json")
        try Data(#"{"trunc"#.utf8).write(to: clipsURL)

        let store = try ClipStore(
            storageDirectory: directory,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let quarantined = directory.appendingPathComponent("clips.json.corrupt-19700101-001640")
        #expect(store.items.isEmpty)
        #expect(store.quarantinedFileURL?.lastPathComponent == quarantined.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(!FileManager.default.fileExists(atPath: clipsURL.path))
        #expect(try Data(contentsOf: quarantined) == Data(#"{"trunc"#.utf8))
    }

    @Test("a corrupt paired-devices.json is quarantined and the store starts empty")
    func corruptPairedDevicesFileIsQuarantinedAndStoreStartsEmpty() async throws {
        let directory = try temporaryDirectory()
        let devicesURL = directory.appendingPathComponent("paired-devices.json")
        try Data(#"{"trunc"#.utf8).write(to: devicesURL)

        let store = try PairedDeviceStore(
            storageURL: devicesURL,
            keyStorage: FileInMemoryPairKeyStorage(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let quarantined = directory.appendingPathComponent("paired-devices.json.corrupt-19700101-001640")
        #expect(await store.devices.isEmpty)
        #expect(store.quarantinedFileURL?.lastPathComponent == quarantined.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(!FileManager.default.fileExists(atPath: devicesURL.path))
    }

    @Test("quarantine never overwrites an earlier quarantined copy")
    func quarantineKeepsEarlierCopies() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("clips.json")
        let at = Date(timeIntervalSince1970: 1_000)

        try Data("first".utf8).write(to: url)
        let first = try CorruptStateFile.quarantine(url, now: at)
        try Data("second".utf8).write(to: url)
        let second = try CorruptStateFile.quarantine(url, now: at)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test("a healthy clips.json is not quarantined")
    func healthyClipsFileIsNotQuarantined() throws {
        let directory = try temporaryDirectory()
        _ = try ClipStore(storageDirectory: directory).addText("kept")

        let reloaded = try ClipStore(storageDirectory: directory)

        #expect(reloaded.items.map(\.text) == ["kept"])
        #expect(reloaded.quarantinedFileURL == nil)
    }
}
