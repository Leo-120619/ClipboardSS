import SwiftUI
import AppKit
import ClipboardCore

struct DevicesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: PeerBrowser
    @ObservedObject var coordinator: PairingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var enteredCode = ""

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
                    if let code = coordinator.hostCode {
                        Text("Show this code on the other device:")
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
                        HStack {
                            TextField("6-digit code", text: $enteredCode)
                                .onChange(of: enteredCode) { value in
                                    let digits = value.filter(\.isNumber)
                                    enteredCode = String(digits.prefix(6))
                                }
                            Button("Connect") {
                                model.joinWithCode(enteredCode)
                            }
                            .disabled(enteredCode.count != 6 || model.joinInProgress)
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
                if isPaired {
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

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.headline)
                if let host = device.host {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Connected", isOn: Binding(
                get: { device.connected },
                set: { model.setDeviceConnected(device.id, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            Button("Send File…") {
                presentOpenPanel()
            }
            .disabled(model.resolvePeer(for: device.id) == nil)
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
