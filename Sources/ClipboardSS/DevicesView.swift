import SwiftUI
import AppKit
import ClipboardCore

struct DevicesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: PeerBrowser
    @ObservedObject var coordinator: PairingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var enteredCode = ""
    @State private var selectedPeerId: UUID?

    init(model: AppModel) {
        self.model = model
        self.browser = model.peerBrowser
        self.coordinator = model.pairingCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            List {
                Section("Pair a device") {
                    if let comparison = coordinator.hostComparison {
                        PairingComparisonView(
                            localName: coordinator.identity.name,
                            comparison: comparison,
                            onConfirm: model.confirmHostedPairing,
                            onCancel: model.cancelHostedPairing
                        )
                    } else if let comparison = coordinator.joinComparison {
                        PairingComparisonView(
                            localName: coordinator.identity.name,
                            comparison: comparison,
                            onConfirm: model.confirmJoin,
                            onCancel: model.cancelJoin
                        )
                    } else if let code = coordinator.hostCode {
                        Text("Enter this code on the other device:")
                            .font(.caption)
                        Text(code)
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                        Button("Stop") {
                            model.stopHostingCode()
                        }
                    } else {
                        Button("Show pairing code") {
                            _ = model.showPairingCode()
                        }
                        Picker("Pair with", selection: $selectedPeerId) {
                            Text("Choose a device").tag(UUID?.none)
                            ForEach(joinablePeers, id: \.id) { peer in
                                Text("\(peer.name) (\(peer.host))").tag(Optional(peer.id))
                            }
                        }
                        HStack {
                            Button(model.scanInProgress ? "Scanning…" : "Scan network") {
                                model.scanForDevices()
                            }
                            .disabled(model.scanInProgress)
                            Spacer()
                        }
                        HStack {
                            TextField("6-digit code", text: $enteredCode)
                                .onChange(of: enteredCode) { value in
                                    let digits = value.filter(\.isNumber)
                                    enteredCode = String(digits.prefix(6))
                                }
                            Button("Connect") {
                                if let peer = selectedPeer {
                                    model.joinWithCode(enteredCode, peer: peer)
                                }
                            }
                            .disabled(enteredCode.count != 6 || selectedPeer == nil || model.joinInProgress)
                        }
                    }
                }

                Section("Paired Devices") {
                    if model.pairedDevices.isEmpty {
                        Text("No paired devices")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pairedDevices, id: \.id) { device in
                            PairedDeviceRow(device: device, model: model)
                        }
                    }
                }

                Section("Nearby Devices") {
                    if browser.peers.isEmpty {
                        Text("Searching for nearby devices...")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(browser.peers, id: \.id) { peer in
                            DeviceRow(peer: peer, model: model)
                        }
                    }
                }

                if !model.transfers.isEmpty {
                    Section("Transfers") {
                        ForEach(model.transfers) { transfer in
                            TransferRow(transfer: transfer, model: model)
                        }
                        Button("Clear finished") {
                            model.clearFinishedTransfers()
                        }
                    }
                }

                if let error = model.lastError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }

    /// Devices the user can pick to pair with: discovered, not paired yet, and on protocol v2.
    private var joinablePeers: [Peer] {
        model.pairingCandidates.filter { peer in
            !peer.needsUpdate && !model.pairedDevices.contains(where: { $0.id == peer.id })
        }
    }

    private var selectedPeer: Peer? {
        joinablePeers.first(where: { $0.id == selectedPeerId })
    }
}

/// Both device names and the 6-digit number, with Confirm / Cancel.
struct PairingComparisonView: View {
    let localName: String
    let comparison: PairingComparison
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(localName) ↔ \(comparison.deviceName)")
                .font(.headline)
            Text("Check that \(comparison.deviceName) shows the same number:")
                .font(.caption)
            Text(comparison.confirmCode)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .accessibilityLabel("Confirmation number \(comparison.confirmCode.map(String.init).joined(separator: " "))")
            if comparison.localConfirmed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(comparison.deviceName) to confirm…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Numbers match", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(comparison.localConfirmed)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeviceRow: View {
    let peer: Peer
    @ObservedObject var model: AppModel
    @State private var isPaired = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(peer.name)
                    .font(.headline)
                if peer.needsUpdate {
                    Text("Needs update")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(ProtocolMismatch.updateOtherDeviceMessage)
                } else if isPaired {
                    Text("Paired")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(peer.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if isPaired {
                Button("Unpair") {
                    model.unpairDevice(peer.id)
                    checkPairedStatus()
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            checkPairedStatus()
        }
        .onChange(of: model.pairedDevices.count) { _ in
            checkPairedStatus()
        }
    }

    private func checkPairedStatus() {
        self.isPaired = model.pairedDevices.contains(where: { $0.id == peer.id })
    }
}

struct PairedDeviceRow: View {
    let device: PairedDevice
    @ObservedObject var model: AppModel

    private var isOnline: Bool {
        model.isDeviceOnline(device.id)
    }

    private var isConnected: Bool {
        AppModel.isDeviceConnectionActive(enabled: device.connected, online: isOnline)
    }

    private var needsUpdate: Bool {
        model.deviceNeedsUpdate(device.id)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOnline ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(isOnline ? "Online" : "Offline")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isOnline ? Color.green : Color.secondary)
                    if let host = device.host {
                        Text("· \(host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.deviceClockSkewed(device.id) {
                        Text("· Clock out of sync")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .help(ProtocolMismatch.clockOutOfSyncMessage(deviceNames: [device.name]))
                    }
                    if needsUpdate {
                        Text("· Needs update")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .help(ProtocolMismatch.updateOtherDeviceMessage)
                    }
                }
            }
            Spacer()
            Button(isConnected ? "Disconnect" : "Connect") {
                model.setDeviceConnected(device.id, !isConnected)
            }
            Button("Send File…") {
                presentOpenPanel()
            }
            .disabled(!isOnline || needsUpdate || model.resolvePeer(for: device.id) == nil)
            Button("Unpair") {
                model.unpairDevice(device.id)
            }
        }
        .padding(.vertical, 4)
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        if panel.runModal() == .OK, let url = panel.url {
            model.sendFile(url: url, to: device.id)
        }
    }
}

struct TransferRow: View {
    let transfer: FileTransferState
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: transfer.direction == .sending ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text(transfer.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusView
            }
            if transfer.isActive {
                ProgressView(value: transfer.progress)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusView: some View {
        switch transfer.status {
        case .inProgress:
            if transfer.direction == .sending {
                Button("Cancel") { model.cancelTransfer(id: transfer.id) }
                    .buttonStyle(.borderless)
            } else {
                Text("\(Int(transfer.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .completed:
            HStack(spacing: 8) {
                Text("Done").font(.caption).foregroundStyle(.green)
                if let url = transfer.destinationURL {
                    Button("Reveal") { model.revealInFinder(url) }
                        .buttonStyle(.borderless)
                }
            }
        case .unconfirmed:
            Text("Sent, not confirmed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(FileTransferState.unconfirmedMessage)
        case let .failed(reason):
            Text("Failed")
                .font(.caption)
                .foregroundStyle(.red)
                .help(reason)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
