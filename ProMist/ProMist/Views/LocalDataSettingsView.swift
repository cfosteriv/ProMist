// App-local reset UI. It coordinates SwiftData and credential deletion so a
// visible device record cannot outlive the owner's intended local cleanup.
import SwiftData
import SwiftUI

struct LocalDataSettingsView: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    @Environment(BreezeLibrary.self) private var breezeLibrary
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KnownFan.lastConnectedAt, order: .reverse)
    private var knownFans: [KnownFan]
    @State private var confirmingReset = false
    @State private var resetError: String?
    let didReset: () -> Void

    init(didReset: @escaping () -> Void = {}) {
        self.didReset = didReset
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Stored fans") {
                    if knownFans.isEmpty {
                        Text("No locally stored fans")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(knownFans) { fan in
                            LabeledContent(fan.name) {
                                Text(fan.hasBLEIdentity
                                     ? String(format: "%06llX", fan.deviceID & 0xFFFFFF)
                                     : "Apple Home only")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }

                Section("Reset") {
                    Button("Reset All Local Data", role: .destructive) {
                        confirmingReset = true
                    }
                    Text("Erases fan history, owner credentials, app preferences, and the current BLE session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset all ProMist data?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Erase Everything", role: .destructive) { resetAllData() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every locally stored fan record. It cannot be undone.")
            }
            .alert("Reset Failed", isPresented: Binding(
                get: { resetError != nil },
                set: { if !$0 { resetError = nil } }
            )) {
                Button("OK") { resetError = nil }
            } message: {
                Text(resetError ?? "Unknown error")
            }
        }
    }

    private func resetAllData() {
        do {
            try bluetooth.resetAllLocalData(
                deviceIDs: knownFans.filter(\.hasBLEIdentity).map(\.deviceID)
            )
            breezeLibrary.reset()
            knownFans.forEach(modelContext.delete)
            try modelContext.save()
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            didReset()
            dismiss()
        } catch {
            resetError = error.localizedDescription
        }
    }
}
