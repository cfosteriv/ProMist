// Enrollment and Apple Home import flows. Discovery results remain temporary
// until full identity verification, ownership, and first state reconciliation.
import SwiftData
import SwiftUI

struct FanPickerView: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    @Environment(ProMistHomeManager.self) private var home
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var knownFans: [KnownFan]
    @State private var connectionError: String?
    @State private var showingHomeImport = false
    @State private var importError: String?

    private var availableFans: [ProMistBLECentral.DiscoveredFan] {
        let knownIdentifiers = Set(knownFans.compactMap(\.peripheralIdentifier))
        return bluetooth.discoveredFans.filter { discovered in
            !knownIdentifiers.contains(discovered.id) &&
                !knownFans.contains { known in
                    known.hasBLEIdentity &&
                    ProMistBLEProtocol.advertisementNameMatches(
                        observedName: discovered.name,
                        expectedName: known.advertisedName,
                        deviceID: known.deviceID
                    )
                }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if bluetooth.connectionState == .connecting {
                    connectionProgress("Connecting to \(bluetooth.discoveredName)…")
                } else if bluetooth.connectionState == .discovering {
                    connectionProgress("Pairing and updating fan state…")
                } else if case .failed(let message) = bluetooth.connectionState {
                    ContentUnavailableView {
                        Label("Couldn’t Connect", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Search Again") { bluetooth.scan() }
                    }
                } else if availableFans.isEmpty {
                    Text("Searching for nearby new fans…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(availableFans) { fan in
                        Button {
                            bluetooth.connect(to: fan)
                        } label: {
                            HStack {
                                Image(systemName: "fan")
                                Text(fan.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Nearby Fans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Import from Home", systemImage: "house") {
                        showingHomeImport = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if bluetooth.connectionState == .scanning {
                        ProgressView()
                    }
                }
            }
        }
        .onAppear { bluetooth.scan() }
        .onDisappear {
            if bluetooth.connectionState == .scanning {
                bluetooth.stopScanning()
            }
        }
        .onChange(of: bluetooth.connectionState) { _, state in
            if state == .ready { dismiss() }
            if case .failed(let message) = state {
                connectionError = message
            }
        }
        .sheet(isPresented: $showingHomeImport) {
            NavigationStack {
                HomeImportView(knownFans: knownFans) { accessory in
                    let fan = knownFans.first {
                        $0.homeAccessoryIdentifier == accessory.id ||
                            (accessory.matterNodeID != nil &&
                             $0.matterNodeID == accessory.matterNodeID)
                    } ?? KnownFan(
                        deviceID: 0,
                        name: accessory.name
                    )
                    if fan.modelContext == nil {
                        modelContext.insert(fan)
                    }
                    home.associate(accessory, with: fan)
                    do {
                        try modelContext.save()
                        showingHomeImport = false
                        dismiss()
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
        }
        .alert("Couldn’t Add Fan", isPresented: Binding(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button("OK") { connectionError = nil }
        } message: {
            Text(connectionError ?? "The fan could not be paired and updated.")
        }
        .alert("Couldn’t Import Fan", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "The Apple Home fan could not be imported.")
        }
    }

    private func connectionProgress(_ message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HomeImportView: View {
    @Environment(ProMistHomeManager.self) private var home
    @Environment(\.dismiss) private var dismiss
    let knownFans: [KnownFan]
    let onImport: (ProMistHomeAccessory) -> Void

    private var accessories: [ProMistHomeAccessory] {
        home.importableAccessories(excluding: knownFans)
    }

    var body: some View {
        Group {
            if accessories.isEmpty {
                ContentUnavailableView(
                    "No Fans in Apple Home",
                    systemImage: "house",
                    description: Text("No unlinked ProMist accessories are available in your homes.")
                )
            } else {
                List(accessories) { accessory in
                    Button { onImport(accessory) } label: {
                        HStack {
                            Label(accessory.name, systemImage: "fan")
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(accessory.homeName)
                                Text(accessory.isReachable ? "Available" : "Not reachable")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Import from Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
