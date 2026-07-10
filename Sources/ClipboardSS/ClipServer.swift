import Foundation
import Network
import ClipboardCore

public final class ClipServer: @unchecked Sendable {
    private let listener: NWListener
    private let receiver: ClipReceiver
    private let pairingCoordinator: PairingCoordinator
    private let identity: DeviceIdentity
    private let fileReceiver: FileReceiver?

    public init(identity: DeviceIdentity, receiver: ClipReceiver, pairingCoordinator: PairingCoordinator, fileReceiver: FileReceiver? = nil) throws {
        self.identity = identity
        self.receiver = receiver
        self.pairingCoordinator = pairingCoordinator
        self.fileReceiver = fileReceiver
        
        let parameters = NWParameters.tcp
        self.listener = try NWListener(using: parameters, on: 51888)
        
        var txt = NWTXTRecord()
        txt["deviceId"] = identity.id.uuidString
        txt["deviceName"] = Self.bonjourSafeTXTValue(identity.name)
        txt["v"] = "1"
        
        self.listener.service = NWListener.Service(name: identity.id.uuidString, type: "_clipboardss._tcp", domain: "local", txtRecord: txt)
        
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
    }
    
    public func start() {
        listener.start(queue: .global())
    }
    
    public func stop() {
        listener.cancel()
    }
    
    private func handleConnection(_ connection: NWConnection) {
        logToFile("ClipServer: Accepted incoming connection from \(connection.endpoint)")
        connection.start(queue: .global())
        
        @Sendable func receiveNext(accumulatedData: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 100 * 1024 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    connection.cancel()
                    return
                }
                
                if let error = error {
                    logToFile("ClipServer: Connection receive error: \(error)")
                    connection.cancel()
                    return
                }
                
                var nextData = accumulatedData
                if let data = data, !data.isEmpty {
                    nextData.append(data)
                }
                
                do {
                    let request = try HTTPCodec.parseRequest(nextData)
                    logToFile("ClipServer: Successfully parsed request \(request.method) \(request.path)")
                    self.handleRequest(request, on: connection)
                } catch HTTPCodecError.incomplete {
                    if isComplete {
                        logToFile("ClipServer: Connection closed before full request was received")
                        connection.cancel()
                    } else {
                        receiveNext(accumulatedData: nextData)
                    }
                } catch HTTPCodecError.payloadTooLarge {
                    logToFile("ClipServer: Request payload too large")
                    let resp = HTTPResponse(statusCode: 413, headers: [:], body: Data("Payload Too Large".utf8))
                    self.sendResponse(resp, on: connection)
                } catch {
                    logToFile("ClipServer: Failed to parse request: \(error)")
                    let resp = HTTPResponse(statusCode: 400, headers: [:], body: Data("Bad Request".utf8))
                    self.sendResponse(resp, on: connection)
                }
            }
        }
        
        receiveNext(accumulatedData: Data())
    }
    
    private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "GET", request.path == "/v1/id" {
            let resp = HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Self.identityResponseBody(id: identity.id, name: identity.name)
            )
            self.sendResponse(resp, on: connection)
        } else if request.path == "/v1/clip" {
            Task {
                do {
                    let decoder = JSONDecoder()
                    struct EnvelopeRaw: Codable {
                        let v: Int
                        let sourceDeviceId: UUID
                        let nonce: String
                        let ciphertext: String
                    }
                    let envelopeRaw = try decoder.decode(EnvelopeRaw.self, from: request.body)
                    
                    guard let key = try await self.pairingCoordinator.pairedStore.getKey(for: envelopeRaw.sourceDeviceId) else {
                        logToFile("ClipServer: Clipboard receive denied, sender not paired: \(envelopeRaw.sourceDeviceId.uuidString)")
                        let resp = HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
                        self.sendResponse(resp, on: connection)
                        return
                    }
                    
                    let envelope = ClipEnvelope(sourceDeviceId: envelopeRaw.sourceDeviceId, nonce: envelopeRaw.nonce, ciphertext: envelopeRaw.ciphertext)
                    let payload = try envelope.open(pairKey: key)
                    
                    let result = try await self.receiver.receive(payload)
                    let status = (result == .duplicate) ? "duplicate" : "ok"
                    let resp = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"\(status)\"}".utf8))
                    self.sendResponse(resp, on: connection)
                } catch {
                    logToFile("ClipServer: Failed to process inbound clip: \(error)")
                    let resp = HTTPResponse(statusCode: 400, headers: [:], body: Data("Bad Request".utf8))
                    self.sendResponse(resp, on: connection)
                }
            }
        } else if request.path == "/v1/pair/start" {
            Task {
                do {
                    let decoder = JSONDecoder()
                    struct PairStartReq: Codable {
                        let deviceId: UUID
                        let deviceName: String
                        let ephemeralPublicKey: String
                    }
                    let req = try decoder.decode(PairStartReq.self, from: request.body)
                    
                    let targetPub = try await self.pairingCoordinator.handlePairStartRequest(
                        initiatorId: req.deviceId,
                        initiatorName: req.deviceName,
                        initiatorPubKeyBase64: req.ephemeralPublicKey,
                        remoteHost: Self.remoteHost(from: connection.endpoint)
                    )
                    
                    struct PairStartResp: Codable {
                        let deviceId: UUID
                        let deviceName: String
                        let ephemeralPublicKey: String
                    }
                    let targetResp = PairStartResp(deviceId: self.pairingCoordinator.identity.id, deviceName: self.pairingCoordinator.identity.name, ephemeralPublicKey: targetPub.base64EncodedString())
                    let responseData = try JSONEncoder().encode(targetResp)
                    
                    let resp = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: responseData)
                    self.sendResponse(resp, on: connection)
                } catch {
                    logToFile("ClipServer: /v1/pair/start rejected/failed: \(error)")
                    let resp = HTTPResponse(statusCode: 403, headers: [:], body: Data("Rejected".utf8))
                    self.sendResponse(resp, on: connection)
                }
            }
        } else if request.path == "/v1/pair/confirm" {
            Task {
                do {
                    let decoder = JSONDecoder()
                    struct PairConfirmReq: Codable {
                        let deviceId: UUID
                        let proof: String
                    }
                    let req = try decoder.decode(PairConfirmReq.self, from: request.body)
                    
                    let success = try await self.pairingCoordinator.handlePairConfirmRequest(initiatorId: req.deviceId, proofBase64: req.proof)
                    if success {
                        let resp = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"ok\"}".utf8))
                        self.sendResponse(resp, on: connection)
                    } else {
                        logToFile("ClipServer: /v1/pair/confirm failed (verification returned false)")
                        let resp = HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
                        self.sendResponse(resp, on: connection)
                    }
                } catch {
                    logToFile("ClipServer: /v1/pair/confirm error: \(error)")
                    let resp = HTTPResponse(statusCode: 400, headers: [:], body: Data("Bad Request".utf8))
                    self.sendResponse(resp, on: connection)
                }
            }
        } else if request.path.hasPrefix("/v1/file/") {
            handleFileRequest(request, on: connection)
        } else {
            logToFile("ClipServer: 404 Not Found path: \(request.path)")
            let resp = HTTPResponse(statusCode: 404, headers: [:], body: Data("Not Found".utf8))
            self.sendResponse(resp, on: connection)
        }
    }

    private func handleFileRequest(_ request: HTTPRequest, on connection: NWConnection) {
        guard let fileReceiver = fileReceiver else {
            self.sendResponse(HTTPResponse(statusCode: 404, headers: [:], body: Data("Not Found".utf8)), on: connection)
            return
        }

        Task {
            let result: FileTransferResponse
            switch request.path {
            case "/v1/file/offer":
                if let envelope = Self.decodeEnvelope(request.body) {
                    result = await fileReceiver.handleOffer(envelope: envelope)
                } else {
                    result = FileTransferResponse(statusCode: 400, body: Data("{}".utf8))
                }
            case "/v1/file/chunk":
                let transferId = request.headers["x-transfer-id"] ?? ""
                let index = Int(request.headers["x-chunk-index"] ?? "") ?? -1
                result = await fileReceiver.handleChunk(transferId: transferId, chunkIndex: index, body: request.body)
            case "/v1/file/finish":
                if let envelope = Self.decodeEnvelope(request.body) {
                    result = await fileReceiver.handleFinish(envelope: envelope)
                } else {
                    result = FileTransferResponse(statusCode: 400, body: Data("{}".utf8))
                }
            case "/v1/file/cancel":
                if let envelope = Self.decodeEnvelope(request.body) {
                    result = await fileReceiver.handleCancel(envelope: envelope)
                } else {
                    result = FileTransferResponse(statusCode: 400, body: Data("{}".utf8))
                }
            default:
                result = FileTransferResponse(statusCode: 404, body: Data("{}".utf8))
            }
            self.sendResponse(
                HTTPResponse(statusCode: result.statusCode, headers: ["Content-Type": "application/json"], body: result.body),
                on: connection
            )
        }
    }

    static func decodeEnvelope(_ body: Data) -> ClipEnvelope? {
        try? JSONDecoder().decode(ClipEnvelope.self, from: body)
    }
    
    /// Some Android mDNS/NsdManager stacks silently fail to resolve services whose
    /// Bonjour TXT records contain multi-byte UTF-8 (e.g. the curly apostrophe macOS
    /// uses in default computer names like "Leonardo's MacBook"), hiding the service
    /// from discovery entirely rather than just mangling the display name.
    static func bonjourSafeTXTValue(_ value: String) -> String {
        let straightened = value
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")

        return String(String.UnicodeScalarView(straightened.unicodeScalars.filter { $0.isASCII }))
    }

    static func identityResponseBody(id: UUID, name: String) -> Data {
        let dict: [String: Any] = ["deviceId": id.uuidString, "deviceName": name, "v": 1]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    static func remoteHost(from endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            let value: String
            switch host {
            case .ipv4(let address):
                value = "\(address)"
            case .ipv6(let address):
                value = "\(address)"
            case .name(let name, _):
                value = name
            @unknown default:
                value = "\(host)"
            }
            return value.components(separatedBy: "%").first ?? value
        }
        return "\(endpoint)"
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        logToFile("ClipServer: Sending HTTP response \(response.statusCode) (\(response.body.count) bytes)")
        let data = HTTPCodec.encodeResponse(response)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                logToFile("ClipServer: Failed to send response: \(error)")
            } else {
                logToFile("ClipServer: Successfully sent response, cancelling connection")
            }
            connection.cancel()
        })
    }
}
