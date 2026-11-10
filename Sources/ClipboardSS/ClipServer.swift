import Foundation
import Network
import ClipboardCore

public final class ClipServer: @unchecked Sendable {
    private let receiver: ClipReceiver
    private let pairingCoordinator: PairingCoordinator
    private let identity: DeviceIdentity
    private let fileReceiver: FileReceiver?
    private let listenerQueue = DispatchQueue(label: "com.local.ClipboardSS.ClipServer.listener")
    private var listener: NWListener?
    private var retryWorkItem: DispatchWorkItem?
    private var isStarted = false
    private var failureCount = 0
    private let port: NWEndpoint.Port
    private let advertisesService: Bool
    /// How long an accepted connection may take to deliver one complete request.
    private let requestDeadline: TimeInterval

    public init(
        identity: DeviceIdentity,
        receiver: ClipReceiver,
        pairingCoordinator: PairingCoordinator,
        fileReceiver: FileReceiver? = nil,
        port: NWEndpoint.Port = 51888,
        advertisesService: Bool = true,
        requestDeadline: TimeInterval = 15
    ) throws {
        self.identity = identity
        self.receiver = receiver
        self.pairingCoordinator = pairingCoordinator
        self.fileReceiver = fileReceiver
        self.port = port
        self.advertisesService = advertisesService
        self.requestDeadline = requestDeadline
        self.listener = nil
        self.listener = try makeListener()
    }

    public func start() {
        listenerQueue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.startPreparedListener()
        }
    }

    public func stop() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            self.isStarted = false
            self.failureCount = 0
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            let current = self.listener
            self.listener = nil
            current?.cancel()
        }
    }

    /// The port the listener is bound to, once it is ready (tests use an ephemeral port).
    var boundPort: NWEndpoint.Port? {
        listenerQueue.sync { listener?.port }
    }

    static func retryDelaySeconds(failureCount: Int) -> Int {
        var delay = 1
        for _ in 1..<max(1, failureCount) {
            delay = min(delay * 2, 30)
        }
        return delay
    }

    private func makeListener() throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: port)
        if advertisesService {
            var txt = NWTXTRecord()
            txt["deviceId"] = identity.id.uuidString
            txt["deviceName"] = Self.bonjourSafeTXTValue(identity.name)
            txt["v"] = "\(ClipEnvelope.currentVersion)"

            listener.service = NWListener.Service(
                name: identity.id.uuidString,
                type: "_clipboardss._tcp",
                domain: "local",
                txtRecord: txt
            )
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.handleListenerState(state, for: listener)
        }
        return listener
    }

    private func startPreparedListener() {
        guard isStarted else { return }
        if listener == nil {
            do {
                listener = try makeListener()
            } catch {
                failureCount += 1
                logToFile("ClipServer: Could not recreate listener: \(error)")
                scheduleRestart()
                return
            }
        }

        logToFile("ClipServer: Starting listener on TCP \(port)")
        listener?.start(queue: listenerQueue)
    }

    private func handleListenerState(_ state: NWListener.State, for current: NWListener) {
        guard listener === current else { return }
        switch state {
        case .ready:
            failureCount = 0
            logToFile("ClipServer: Listener ready on TCP \(current.port.map { "\($0)" } ?? "?")")
        case .waiting(let error):
            logToFile("ClipServer: Listener waiting for network: \(error)")
        case .failed(let error):
            logToFile("ClipServer: Listener failed: \(error); scheduling recovery")
            listener = nil
            current.cancel()
            failureCount += 1
            scheduleRestart()
        case .cancelled:
            logToFile("ClipServer: Listener cancelled")
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func scheduleRestart() {
        guard isStarted, retryWorkItem == nil else { return }
        let delay = Self.retryDelaySeconds(failureCount: failureCount)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.startPreparedListener()
        }
        retryWorkItem = workItem
        listenerQueue.asyncAfter(deadline: .now() + .seconds(delay), execute: workItem)
    }
    
    /// Largest chunk requested from the socket per receive call.
    static let receiveChunkSize = 64 * 1024

    private func handleConnection(_ connection: NWConnection) {
        logToFile("ClipServer: Accepted incoming connection from \(connection.endpoint)")

        /// Tracks whether this connection has produced a complete request (or was otherwise
        /// resolved) so the accept deadline knows whether to drop it.
        final class RequestDeadlineState: @unchecked Sendable {
            private let lock = NSLock()
            private var resolved = false

            /// Returns true only for the first caller.
            func resolve() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return false }
                resolved = true
                return true
            }
        }
        let deadlineState = RequestDeadlineState()

        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + requestDeadline) {
            guard deadlineState.resolve() else { return }
            logToFile("ClipServer: No complete request within deadline; closing connection")
            connection.cancel()
        }

        @Sendable func resolveDeadline() -> Bool {
            deadlineState.resolve()
        }

        @Sendable func receiveNext(accumulatedData: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    _ = resolveDeadline()
                    connection.cancel()
                    return
                }
                
                if let error = error {
                    logToFile("ClipServer: Connection receive error: \(error)")
                    _ = resolveDeadline()
                    connection.cancel()
                    return
                }
                
                var nextData = accumulatedData
                if let data = data, !data.isEmpty {
                    nextData.append(data)
                }
                
                do {
                    let request = try HTTPCodec.parseRequest(nextData)
                    // The deadline already fired and cancelled this connection.
                    guard resolveDeadline() else { return }
                    logToFile("ClipServer: Successfully parsed request \(request.method) \(request.path)")
                    self.handleRequest(request, on: connection)
                } catch HTTPCodecError.incomplete {
                    if isComplete {
                        logToFile("ClipServer: Connection closed before full request was received")
                        _ = resolveDeadline()
                        connection.cancel()
                    } else {
                        receiveNext(accumulatedData: nextData)
                    }
                } catch HTTPCodecError.payloadTooLarge {
                    guard resolveDeadline() else { return }
                    logToFile("ClipServer: Request payload too large")
                    let resp = HTTPResponse(statusCode: 413, headers: [:], body: Data("Payload Too Large".utf8))
                    self.sendResponse(resp, on: connection)
                } catch HTTPCodecError.headersTooLarge {
                    guard resolveDeadline() else { return }
                    logToFile("ClipServer: Request headers too large")
                    let resp = HTTPResponse(statusCode: 431, headers: [:], body: Data("Request Header Fields Too Large".utf8))
                    self.sendResponse(resp, on: connection)
                } catch {
                    guard resolveDeadline() else { return }
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
                    let envelope = try JSONDecoder().decode(ClipEnvelope.self, from: request.body)
                    guard envelope.v == ClipEnvelope.currentVersion else {
                        logToFile("ClipServer: Clip envelope v\(envelope.v) refused; upgrade required")
                        self.sendResponse(Self.upgradeRequiredResponse(), on: connection)
                        return
                    }

                    guard let key = try await self.pairingCoordinator.pairedStore.getKey(for: envelope.sourceDeviceId) else {
                        logToFile("ClipServer: Clipboard receive denied, sender not paired: \(envelope.sourceDeviceId.uuidString)")
                        let resp = HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
                        self.sendResponse(resp, on: connection)
                        return
                    }
                    guard await self.pairingCoordinator.pairedStore.isConnected(envelope.sourceDeviceId) else {
                        let resp = HTTPResponse(statusCode: 401, headers: [:], body: Data("Unauthorized".utf8))
                        self.sendResponse(resp, on: connection)
                        return
                    }

                    let payload = try envelope.open(
                        ClipPayload.self,
                        purpose: .clip,
                        recipientDeviceId: self.identity.id,
                        pairKey: key
                    )

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
                    
                    let outcome = try await self.pairingCoordinator.handlePairConfirmRequest(initiatorId: req.deviceId, proofBase64: req.proof)
                    switch outcome {
                    case .paired:
                        let resp = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"ok\"}".utf8))
                        self.sendResponse(resp, on: connection)
                    case .alreadyPaired:
                        logToFile("ClipServer: /v1/pair/confirm rejected (device already paired)")
                        let resp = HTTPResponse(statusCode: 409, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"alreadyPaired\"}".utf8))
                        self.sendResponse(resp, on: connection)
                    case .rejected:
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

    static func upgradeRequiredResponse() -> HTTPResponse {
        let upgrade = FileTransferResponse.upgradeRequired
        return HTTPResponse(statusCode: upgrade.statusCode, headers: ["Content-Type": "application/json"], body: upgrade.body)
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
        let dict: [String: Any] = ["deviceId": id.uuidString, "deviceName": name, "v": ClipEnvelope.currentVersion]
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
