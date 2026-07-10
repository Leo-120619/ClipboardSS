import Foundation
import Testing
@testable import ClipboardCore

@Suite("FileTransferPayload JSON shape")
struct FileTransferPayloadTests {
    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("offer payload has exactly the spec field names")
    func offerFieldNames() throws {
        let offer = FileOfferPayload(
            transferId: "6f9619ff-8b86-d011-b42d-00c04fc964ff",
            fileName: "movie.mp4",
            fileSize: 157_286_400,
            mimeType: "video/mp4",
            fileHash: "abc",
            chunkSize: 4_194_304,
            chunkCount: 38,
            createdAt: Date(timeIntervalSince1970: 0),
            sourceDeviceName: "Mac"
        )
        let json = try encode(offer)
        #expect(Set(json.keys) == [
            "transferId", "fileName", "fileSize", "mimeType", "fileHash",
            "chunkSize", "chunkCount", "createdAt", "sourceDeviceName"
        ])
        #expect(json["transferId"] as? String == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(json["chunkSize"] as? Int == 4_194_304)
        #expect(json["createdAt"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test("finish and cancel payloads carry only transferId")
    func finishCancelShape() throws {
        #expect(Set(try encode(FileFinishPayload(transferId: "t")).keys) == ["transferId"])
        #expect(Set(try encode(FileCancelPayload(transferId: "t")).keys) == ["transferId"])
    }

    @Test("offer round-trips through Codable")
    func offerRoundTrips() throws {
        let offer = FileOfferPayload(
            transferId: "t", fileName: "a.bin", fileSize: 10, mimeType: "application/octet-stream",
            fileHash: "h", chunkSize: 4_194_304, chunkCount: 1,
            createdAt: Date(timeIntervalSince1970: 12_345), sourceDeviceName: "Mac"
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FileOfferPayload.self, from: try encoder.encode(offer))
        #expect(decoded == offer)
    }
}
