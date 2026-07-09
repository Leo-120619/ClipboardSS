import SwiftUI
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
            Button("Unpair") {
                model.unpairDevice(device.id)
            }
        }
        .padding(.vertical, 4)
    }
}
