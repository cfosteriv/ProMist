// Per-device identity, naming, Apple Home association, diagnostics, and removal
// controls. Destructive recovery remains an explicit user-confirmed operation.
import SwiftData
import SwiftUI

struct DeviceSettingsView: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    @Environment(ProMistHomeManager.self) private var home
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let knownFan: KnownFan
    let onRemove: () -> Void

    @State private var draftName: String
    @State private var nameError: String?
    @State private var removalError: String?
    @State private var confirmingRemoval = false
    @State private var isRemoving = false
    @State private var commissioning = false
    @State private var homeError: String?

    init(knownFan: KnownFan, onRemove: @escaping () -> Void) {
        self.knownFan = knownFan
        self.onRemove = onRemove
        _draftName = State(initialValue: knownFan.name)
    }

    private var normalizedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameByteCount: Int {
        normalizedName.utf8.count
    }

    private var nameIsValid: Bool {
        !normalizedName.isEmpty &&
            nameByteCount <= ProMistBLEProtocol.maximumFriendlyNameByteCount &&
            !normalizedName.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private var deviceIsReady: Bool {
        knownFan.hasBLEIdentity && bluetooth.connectionState == .ready &&
            bluetooth.deviceState.deviceID == knownFan.deviceID
    }

    private var shouldShowAppleHome: Bool {
        let status = home.status(for: knownFan)
        return status.isInHome || knownFan.isMatterCommissioned ||
            !knownFan.hasBLEIdentity ||
            (deviceIsReady && bluetooth.capabilities.canProvideMatterOnboarding)
    }

    var body: some View {
        NavigationStack {
            Form {
                if deviceIsReady && bluetooth.capabilities.canRenameDevice {
                    Section("Name") {
                        VStack (spacing: 8) {
                            TextField("Fan name", text: $draftName)
                                .textInputAutocapitalization(.words)
                                .listRowSeparator(.hidden)

                            if let nameError {
                                Text(nameError)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .listRowSeparator(.hidden)
                            } else {
                                Text(" Maximum 24 characters (\(nameByteCount)/24).")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .listRowSeparator(.hidden)
                            }

                            Button(action: {
                                saveName()
                            }, label: {
                                Text("Save Name")
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .contentShape(Capsule())
                            })
                            .proMistGlassButton(prominent: true)
                            .disabled(
                                !nameIsValid ||
                                normalizedName == knownFan.name
                            )
                            .listRowSeparator(.hidden)
                        }
                    }
                }

                if deviceIsReady && bluetooth.capabilities.canReadDiagnostics {
                    Section("Diagnostics") {
                        diagnosticLink(.fanSpeed)
                        diagnosticLink(.mist)
                        diagnosticLink(.rotation)
                    }
                    .accessibilityIdentifier("diagnostics-controls")
                }

                if shouldShowAppleHome {
                    Section("Apple Home") {
                        let homeStatus = home.status(for: knownFan)
                        if homeStatus.isInHome {
                            Label(
                                homeStatus.isReachable
                                    ? "Available in Apple Home"
                                    : "In Apple Home · Not reachable",
                                systemImage: "house.fill"
                            )
                        } else if knownFan.isMatterCommissioned {
                            Label("Added to a Matter home", systemImage: "house")
                            Text("Use Import from Home on the Add Device screen to link its Apple Home accessory.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if knownFan.hasBLEIdentity &&
                                    bluetooth.capabilities.canProvideMatterOnboarding {
                            Button("Add Fan to Home", systemImage: "house.badge.plus") {
                                commissioning = true
                                Task { @MainActor in
                                    defer { commissioning = false }
                                    defer {
                                        bluetooth.finishMatterCommissioningHandoff()
                                        bluetooth.resumeDeviceSession(
                                            deviceID: knownFan.deviceID,
                                            name: knownFan.advertisedName
                                        )
                                    }
                                    do {
                                        // Validate Home authorization before ending
                                        // the working proprietary BLE session.
                                        try home.validateMatterSetupAccess()
                                        let onboardingPayload = try await bluetooth.matterOnboardingPayload(
                                            deviceID: knownFan.deviceID
                                        )
                                        try await bluetooth.disconnectForMatterCommissioning(
                                            deviceID: knownFan.deviceID
                                        )
                                        try await home.commission(
                                            knownFan,
                                            onboardingPayload: onboardingPayload
                                        )
                                        try modelContext.save()
                                    } catch {
                                        homeError = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(
                                !deviceIsReady || !bluetooth.isAuthenticated ||
                                bluetooth.deviceState.matterCommissioning == .notConfigured ||
                                commissioning
                            )

                            if commissioning {
                                ProgressView("Handing off to Apple Home…")
                            }
                        } else if !knownFan.hasBLEIdentity {
                            Label("Imported from Apple Home", systemImage: "house.fill")
                            Text("Bluetooth controls are unavailable until this Home accessory is paired with the nearby ProMist fan.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Remove Device", role: .destructive) {
                        confirmingRemoval = true
                    }
                    .disabled(isRemoving)

                    if !canResetRemoteOwnership {
                        Text("The fan is not connected. Removing it will forget its local credential, Bluetooth session, and saved app record. The fan itself will not be reset.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if isRemoving {
                        ProgressView("Resetting ownership…")
                    }

                    if let removalError {
                        Text(removalError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Device Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if bluetooth.isDeviceIOInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove \(knownFan.name)?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Device", role: .destructive) {
                    removeDevice()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if canResetRemoteOwnership {
                    Text("This resets ownership on the fan, removes its Keychain credential and local Bluetooth session, and deletes it from this iPhone.")
                } else {
                    Text("This deletes the fan’s Keychain credential, local Bluetooth session, and saved app record. Because the fan is unreachable, ownership stored on the fan cannot be reset.")
                }
            }
            .alert("Apple Home", isPresented: Binding(
                get: { homeError != nil },
                set: { if !$0 { homeError = nil } }
            )) {
                Button("OK") { homeError = nil }
            } message: {
                Text(homeError ?? "")
            }
            .onChange(of: bluetooth.discoveredName) { _, name in
                guard bluetooth.deviceState.deviceID == knownFan.deviceID else {
                    return
                }
                draftName = name
                nameError = nil
            }
            .task(id: deviceIsReady) {
                if deviceIsReady && bluetooth.capabilities.canReadDiagnostics {
                    bluetooth.refreshDiagnostics()
                }
            }
            .onChange(of: bluetooth.ownershipResetCompletedDeviceID) { _, deviceID in
                guard isRemoving, deviceID == knownFan.deviceID else { return }
                finishDeviceRemoval()
            }
        }
    }

    private func diagnosticLink(_ category: DiagnosticCategory) -> some View {
        NavigationLink {
            DiagnosticsView(category: category)
        } label: {
            HStack {
                Label(category.title, systemImage: category.systemImage)
                Spacer()
                if faultCount(for: category) != 0 {
                    Text(faultCount(for: category), format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(
                            "\(faultCount(for: category)) stored faults"
                        )
                }
            }
        }
        .disabled(!deviceIsReady)
        .settingsRowSeparator()
    }

    private func faultCount(for category: DiagnosticCategory) -> Int {
        bluetooth.diagnostics.count {
            $0.component == category.component && $0.severity >= 2
        }
    }

    private func saveName() {
        guard nameIsValid else {
            nameError = "Enter a name between 1 and 24 UTF-8 bytes."
            return
        }
        guard bluetooth.setFriendlyName(normalizedName) else {
            nameError = "The name could not be sent. Make sure the fan is connected."
            return
        }
        nameError = nil
    }

    private func removeDevice() {
        removalError = nil
        if !canResetRemoteOwnership {
            finishDeviceRemoval()
            return
        }

        guard knownFan.hasBLEIdentity,
              bluetooth.resetOwnership(deviceID: knownFan.deviceID) else {
            removalError = "The ownership reset could not be started. Disconnect the fan and try removing it locally."
            return
        }
        isRemoving = true
    }

    private func finishDeviceRemoval() {
        let deviceID = knownFan.deviceID
        let peripheralIdentifier = knownFan.peripheralIdentifier
        do {
            try LocalDeviceRemovalCoordinator.remove(
                securityDeletionRequired: deviceID != 0,
                deleteCredential: {
                    try bluetooth.forgetLocalDevice(
                        deviceID: deviceID,
                        peripheralIdentifier: peripheralIdentifier
                    )
                },
                deletePersistentRecord: {
                    modelContext.delete(knownFan)
                    try modelContext.save()
                }
            )
            onRemove()
            dismiss()
        } catch {
            removalError = "The device could not be removed: \(error.localizedDescription)"
        }
    }

    private var canResetRemoteOwnership: Bool {
        deviceIsReady && bluetooth.isAuthenticated
    }
}

private extension View {
    func settingsRowSeparator() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions.width
            }
    }
}
