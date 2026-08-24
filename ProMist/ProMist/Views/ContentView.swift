// Root navigation and device-lifecycle view. It persists a fan only after the
// BLE coordinator has authenticated and published authoritative device state.
import SwiftData
import SwiftUI

struct ContentView: View {
    private struct ConnectionAlert: Identifiable {
        enum Action {
            case dismiss
            case removeRecoveredDevice(UInt64)
        }
        let id = UUID()
        let title: String
        let message: String
        let action: Action
    }

    private struct DashboardMonitorID: Hashable {
        let isVisible: Bool
        let knownDeviceIDs: [UInt64]
    }

    @Environment(ProMistBLECentral.self) private var bluetooth
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \KnownFan.lastConnectedAt, order: .reverse)
    private var knownFans: [KnownFan]
    @State private var selectedFan: KnownFan?
    @State private var showingFanPicker = false
    @State private var showingSettings = false
    @State private var selectedFanReachedReady = false
    @State private var connectionAlert: ConnectionAlert?

    var body: some View {
        NavigationStack {
            DashboardView(
                selectedFan: $selectedFan,
                showingFanPicker: $showingFanPicker,
                showingSettings: $showingSettings
            )
        }
        .sheet(isPresented: $showingFanPicker) {
            FanPickerView()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingSettings) {
            LocalDataSettingsView {
                selectedFan = nil
            }
        }
        .onChange(of: bluetooth.deviceState) { _, state in
            recordKnownFan(state)
        }
        .onChange(of: bluetooth.discoveredName) { _, _ in
            recordKnownFan(bluetooth.deviceState)
        }
        .onChange(of: selectedFan?.deviceID) { _, deviceID in
            selectedFanReachedReady = deviceID != nil &&
                bluetooth.connectionState == .ready &&
                bluetooth.deviceState.deviceID == deviceID
        }
        .onChange(of: bluetooth.connectionState) { _, state in
            if state == .ready {
                recordKnownFan(bluetooth.deviceState)
            }
            handleSelectedFanConnectionState(state)
        }
        .task(id: dashboardMonitorID) {
            await monitorKnownFansWhileDashboardIsVisible()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                bluetooth.cancelKnownFanRefresh()
            }
        }
        .onAppear { publishIntentDevices() }
        .onChange(of: knownFans.map(\.deviceID)) { _, _ in publishIntentDevices() }
        .alert(item: $connectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    handleConnectionAlertAction(alert.action)
                }
            )
        }
        .accessibilityIdentifier("promist-root")
    }

    private func publishIntentDevices() {
        UserDefaults.standard.set(knownFans.filter(\.hasBLEIdentity).map {
            ["id": NSNumber(value: $0.deviceID), "name": $0.name]
        }, forKey: "ProMistIntentDevices")
    }

    private var dashboardMonitorID: DashboardMonitorID {
        DashboardMonitorID(
            isVisible: scenePhase == .active &&
                selectedFan == nil &&
                !showingFanPicker &&
                !showingSettings,
            knownDeviceIDs: knownFans.filter(\.hasBLEIdentity).map(\.deviceID).sorted()
        )
    }

    private func monitorKnownFansWhileDashboardIsVisible() async {
        guard dashboardMonitorID.isVisible else { return }
        while !Task.isCancelled {
            bluetooth.expireSessionSnapshots()
            refreshKnownFansIfNeeded()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }

    private func handleSelectedFanConnectionState(
        _ state: ProMistConnectionState
    ) {
        guard selectedFan != nil else { return }

        if state == .ready {
            selectedFanReachedReady = true
            return
        }

        guard case .failed(let message) = state else { return }
        let failedFan = selectedFan
        let wasConnected = selectedFanReachedReady
        selectedFan = nil
        selectedFanReachedReady = false
        if let deviceID = failedFan?.deviceID,
           bluetooth.recoveryRequiredDeviceID == deviceID {
            connectionAlert = ConnectionAlert(
                title: "Fan Ownership Was Reset",
                message: "This fan no longer recognizes its saved owner. Tap OK to remove the old pairing from this app, then hold the fan button for five seconds to enter pairing mode and select the fan again.",
                action: .removeRecoveredDevice(deviceID)
            )
            return
        }
        connectionAlert = ConnectionAlert(
            title: wasConnected ? "Connection Lost" : "Couldn’t Connect",
            message: message,
            action: .dismiss
        )
    }

    private func handleConnectionAlertAction(_ action: ConnectionAlert.Action) {
        guard case .removeRecoveredDevice(let deviceID) = action else { return }
        do {
            try LocalDeviceRemovalCoordinator.remove(
                securityDeletionRequired: true,
                deleteCredential: {
                    try bluetooth.forgetRecoveredDevice(deviceID: deviceID)
                },
                deletePersistentRecord: {
                    if let fan = knownFans.first(where: { $0.deviceID == deviceID }) {
                        modelContext.delete(fan)
                        try modelContext.save()
                    }
                }
            )
            showingFanPicker = true
        } catch {
            connectionAlert = ConnectionAlert(
                title: "Couldn’t Remove Fan",
                message: "The owner credential could not be removed, so the fan record was preserved. Try again. \(error.localizedDescription)",
                action: .dismiss
            )
        }
    }

    private func refreshKnownFansIfNeeded() {
        guard dashboardMonitorID.isVisible else { return }
        // Refresh older records first so the most recently used fan can remain
        // as the app's active connection after every tile has been updated.
        bluetooth.refreshKnownFans(knownFans.reversed().filter(\.hasBLEIdentity).map {
            ProMistBLECentral.KnownFanTarget(
                deviceID: $0.deviceID,
                name: $0.advertisedName
            )
        })
    }

    private func recordKnownFan(_ state: ProMistDeviceState) {
        // Discovery and authoritative identity reads occur before ownership is
        // proven. Never promote those partial sessions into the known list.
        guard state.deviceID != 0,
              bluetooth.connectionState == .ready,
              bluetooth.isAuthenticated else { return }

        do {
            let descriptor = FetchDescriptor<KnownFan>()
            let knownFans = try modelContext.fetch(descriptor)
            if let existing = knownFans.first(where: {
                $0.deviceID == state.deviceID
            }) {
                let snapshotChanged =
                    existing.name != bluetooth.discoveredName ||
                    existing.peripheralIdentifier != bluetooth.selectedPeripheralIdentifier ||
                    existing.lastPower != state.power ||
                    existing.lastFanSpeed != state.fanSpeed ||
                    existing.lastMistMode != state.mistMode ||
                    existing.lastBreezeMode != state.breezeMode ||
                    existing.lastOscillationMode != state.oscillationMode ||
                    existing.lastFault != state.fault
                let timestampNeedsRefresh =
                    Date.now.timeIntervalSince(existing.lastConnectedAt) >= 30
                guard snapshotChanged || timestampNeedsRefresh else { return }
                existing.update(
                    name: bluetooth.discoveredName,
                    peripheralIdentifier: bluetooth.selectedPeripheralIdentifier,
                    state: state
                )
            } else {
                modelContext.insert(KnownFan(
                    deviceID: state.deviceID,
                    peripheralIdentifier: bluetooth.selectedPeripheralIdentifier,
                    name: bluetooth.discoveredName,
                    state: state
                ))
            }
            try modelContext.save()
#if DEBUG
            print("[ProMist Data] Saved fan \(bluetooth.discoveredName) device=\(state.deviceID)")
#endif
        } catch {
#if DEBUG
            print("[ProMist Data] Failed to save known fan: \(error)")
#endif
        }
    }
}

@MainActor
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(ProMistBLECentral.preview)
            .modelContainer(for: KnownFan.self, inMemory: true)
    }
}
