// Interactive control surface for one fan. Displayed controls follow the
// firmware's authoritative snapshot rather than optimistic local toggles.
import SwiftUI
import SwiftData

struct DeviceView: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    @Environment(BreezeLibrary.self) private var breezeLibrary
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDeviceSettings = false
    @State private var showingBreezeLibrary = false
    @State private var editingBreezePreset: BreezePreset?
    @State private var pendingBreezePreset: BreezePreset?
    @State private var isClearingFault = false
    @State private var faultClearMessage: String?
    let knownFan: KnownFan
    let onRemove: () -> Void

    init(
        knownFan: KnownFan,
        onRemove: @escaping () -> Void = {}
    ) {
        self.knownFan = knownFan
        self.onRemove = onRemove
    }

    private var state: ProMistDeviceState { bluetooth.deviceState }

    private var connectionState: ProMistConnectionState {
        bluetooth.connectionState(
            forDeviceID: knownFan.deviceID,
            peripheralIdentifier: knownFan.peripheralIdentifier
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            deviceActionRow

            Divider()

            if connectionState == .ready {
                if state.fault != 0 && bluetooth.capabilities.canClearFaults {
                    faultRecovery
                    Divider()
                }
                controls
            } else {
                connectionContent
            }
        }
        .sheet(isPresented: $showingDeviceSettings) {
            DeviceSettingsView(knownFan: knownFan) {
                showingDeviceSettings = false
                bluetooth.disconnect()
                onRemove()
            }
        }
        .sheet(isPresented: $showingBreezeLibrary) {
            BreezeLibraryView()
        }
        .sheet(item: $editingBreezePreset) { preset in
            BreezeEditorView(preset: preset) {
                breezeLibrary.save($0)
                editingBreezePreset = nil
            }
        }
        .confirmationDialog(
            "Install \(pendingBreezePreset?.name ?? "Breeze")",
            isPresented: Binding(
                get: { pendingBreezePreset != nil },
                set: { if !$0 { pendingBreezePreset = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let preset = pendingBreezePreset {
                ForEach(0..<3, id: \.self) { slot in
                    Button(breezeSlotInstallLabel(slot)) {
                        bluetooth.installAndSelectBreeze(preset, slot: slot)
                        pendingBreezePreset = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingBreezePreset = nil }
        } message: {
            Text("The fan keeps three custom breezes. Replacing a slot does not remove either preset from your iPhone library.")
        }
        .onAppear { connectIfNeeded() }
        .onDisappear {
            bluetooth.endDeviceSession(deviceID: knownFan.deviceID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                bluetooth.resumeDeviceSession(
                    deviceID: knownFan.deviceID,
                    name: knownFan.advertisedName
                )
            }
        }
        .alert("Fault Recovery", isPresented: Binding(
            get: { faultClearMessage != nil },
            set: { if !$0 { faultClearMessage = nil } }
        )) {
            Button("OK") { faultClearMessage = nil }
        } message: {
            Text(faultClearMessage ?? "")
        }
    }

    private var faultRecovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(faultDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)

            Text("Clear the fault after checking the fan. The fan will turn off, and stored diagnostics will be kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                clearFault()
            } label: {
                if isClearingFault {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Clear Fault")
                        .frame(maxWidth: .infinity)
                }
            }
            .proMistGlassButton(prominent: true)
            .disabled(isClearingFault || !bluetooth.isAuthenticated)
            .accessibilityIdentifier("clear-fault-button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var faultDescription: String {
        switch state.fault {
        case 1: "Rotation is finding its home position"
        case 2: "Fan speed is lower than expected"
        case 3: "Rotation safety fault"
        case 4: "Fan speed is too high"
        case 5: "Fan is not turning"
        case 6: "Fan hardware did not start"
        default: "Device fault"
        }
    }

    private func clearFault() {
        guard !isClearingFault else { return }
        isClearingFault = true
        Task { @MainActor in
            defer { isClearingFault = false }
            do {
                try await bluetooth.clearFaults()
                knownFan.lastFault = 0
                knownFan.lastPower = false
                do {
                    try modelContext.save()
                    faultClearMessage = "The fault was cleared and the fan was turned off."
                } catch {
                    faultClearMessage = "The fan cleared the fault and turned off, but the app could not save the updated status."
                }
            } catch {
                faultClearMessage = "The fault could not be cleared. \(error.localizedDescription)"
            }
        }
    }

    private var deviceActionRow: some View {
        HStack(spacing: 12) {
            if bluetooth.capabilities.canControlPower {
                Button {
                    bluetooth.togglePower()
                } label: {
                    Image(systemName: state.power ? "power" : "power.dotted")
                        .foregroundStyle(state.power ? .green : .primary)
                        .frame(width: 30, height: 30)
                }
                .proMistGlassButton()
                .disabled(connectionState != .ready)
                .accessibilityLabel(
                    state.power ? "Turn fan off" : "Turn fan on"
                )

                Spacer()
            }

            if bluetooth.capabilities.canControlMist {
                Button {
                    bluetooth.setMist(state.mistMode == 0)
                } label: {
                    Image(systemName: "drop.fill")
                        .foregroundStyle(state.mistMode != 0 ? .blue : .primary)
                        .frame(width: 30, height: 30)
                }
                .proMistGlassButton()
                .disabled(connectionState != .ready || !state.power)
                .accessibilityLabel(
                    state.mistMode != 0 ? "Turn mist off" : "Turn mist on"
                )
                .accessibilityIdentifier("mist-controls")

                Spacer()
            }

            if bluetooth.capabilities.canControlOscillation {
                Button {
                    bluetooth.setOscillation(nextOscillationMode)
                } label: {
                    Image(systemName: "fan.oscillation")
                        .foregroundStyle(
                            state.oscillationMode != 0 ? .orange : .primary
                        )
                        .frame(width: 30, height: 30)
                }
                .proMistGlassButton()
                .disabled(connectionState != .ready || !state.power)
                .accessibilityLabel("Rotation")
                .accessibilityValue(oscillationModeLabel)
                .accessibilityHint(
                    "Sets rotation to \(nextOscillationModeLabel)"
                )

                Spacer()
            }

            if bluetooth.capabilities.canSetTimer {
                Menu {
                    ForEach([15, 30, 45, 60], id: \.self) { minutes in
                        Button(timerPresetLabel(minutes)) {
                            bluetooth.setTimer(minutes: UInt8(minutes))
                        }
                    }
                    if state.timerRemainingSeconds > 0 {
                        Divider()
                        Button("Cancel Timer", role: .destructive) {
                            bluetooth.setTimer(minutes: nil)
                        }
                    }
                } label: {
                    ProMistTimerIndicator(
                        remainingSeconds: state.timerRemainingSeconds,
                        durationSeconds: state.timerDurationSeconds
                    )
                    .frame(width: 30, height: 30)
                }
                .proMistGlassButton()
                .disabled(connectionState != .ready || !state.power)
                .accessibilityLabel("Timer")
                .accessibilityValue(timerAccessibilityValue)
                .accessibilityIdentifier("timer-controls")

                Spacer()
            }

            Button {
                showingDeviceSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 30, height: 30)
            }
            .proMistGlassButton()
            .accessibilityLabel("Device settings")
            .accessibilityIdentifier("device-settings-button")
        }
    }

    private var nextOscillationMode: UInt8 {
        switch state.oscillationMode {
        case 0: 1
        case 1: 2
        case 2: 3
        default: 0
        }
    }

    private var timerAccessibilityValue: String {
        state.timerRemainingSeconds == 0
            ? "Off"
            : "\(timerRemainingLabel(state.timerRemainingSeconds)) remaining"
    }

    private var oscillationModeLabel: String {
        switch state.oscillationMode {
        case 1: "45 degrees"
        case 2: "90 degrees"
        case 3: "180 degrees"
        default: "Off"
        }
    }

    private var nextOscillationModeLabel: String {
        switch nextOscillationMode {
        case 1: "45 degrees"
        case 2: "90 degrees"
        case 3: "180 degrees"
        default: "Off"
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            if bluetooth.capabilities.canControlFanSpeed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Fan Speed")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Picker(
                        "Fan speed",
                        selection: Binding(
                            get: {
                                state.breezeMode == 0
                                    ? Int(state.fanSpeed)
                                    : 0
                            },
                            set: { speed in
                                guard (1...5).contains(speed) else { return }
                                bluetooth.setFanSpeed(UInt8(speed))
                            }
                        )
                    ) {
                        ForEach(1...5, id: \.self) { speed in
                            Text(String(speed)).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fan-controls")
            }

            if bluetooth.capabilities.canControlFanSpeed &&
                bluetooth.capabilities.canUseBreezeModes {
                Divider()
            }

            if bluetooth.capabilities.canUseBreezeModes {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Breeze")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        Button("Off") { bluetooth.setFanSpeed(state.fanSpeed) }
                        Section("Original") {
                            ForEach(BuiltInBreeze.allCases) { breeze in
                                Button {
                                    bluetooth.setBreeze(breeze.rawValue)
                                } label: {
                                    breezeMenuLabel(
                                        breeze.name,
                                        selected: state.breezeMode == breeze.rawValue
                                    )
                                }
                            }
                        }
                        if bluetooth.supportsCustomBreezeSlots {
                            Section("On This Fan") {
                                ForEach(0..<3, id: \.self) { slot in
                                    if let preset = bluetooth.fanBreezeSlots[slot] {
                                        Button {
                                            bluetooth.setBreeze(UInt8(4 + slot))
                                        } label: {
                                            breezeMenuLabel(
                                                preset.name,
                                                selected: state.breezeMode == UInt8(4 + slot)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        if !breezeLibrary.presets.isEmpty {
                            Section("My Breezes") {
                                ForEach(breezeLibrary.presets) { preset in
                                    Button(preset.name) { selectCustomBreeze(preset) }
                                }
                            }
                        }
                        Section {
                            Button("Create New Breeze…") {
                                editingBreezePreset = .fresh()
                            }
                            Button("Manage Breeze Library…") {
                                showingBreezeLibrary = true
                            }
                        }
                        if bluetooth.supportsCustomBreezeSlots,
                           bluetooth.fanBreezeSlots.contains(where: { $0 != nil }) {
                            Section("Remove From Fan") {
                                ForEach(0..<3, id: \.self) { slot in
                                    if let preset = bluetooth.fanBreezeSlots[slot] {
                                        Button("Remove \(preset.name)", role: .destructive) {
                                            bluetooth.clearBreezeSlot(slot)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedBreezeName)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.power)
                }
                .frame(maxWidth: .infinity)
            }

            if (bluetooth.capabilities.canControlFanSpeed ||
                bluetooth.capabilities.canUseBreezeModes) &&
                bluetooth.capabilities.canControlOscillation {
                Divider()
            }

            if bluetooth.capabilities.canControlOscillation {
                OscillationControl(
                    mode: state.oscillationMode,
                    facingPreset: state.oscillationPosition,
                    destinationPreset: bluetooth.capabilities.canPositionOscillation &&
                        state.oscillationPositioning
                        ? state.oscillationTargetPosition
                        : nil,
                    canPosition: bluetooth.capabilities.canPositionOscillation,
                    selectMode: { bluetooth.setOscillation($0) },
                    moveToPreset: { bluetooth.setOscillationPosition($0) },
                    jogClockwise: { bluetooth.jog(1) },
                    jogCounterClockwise: { bluetooth.jog(-1) },
                    home: { bluetooth.home() }
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("oscillation-controls")
            }
        }
    }

    private var selectedBreezeName: String {
        if let builtIn = BuiltInBreeze(rawValue: state.breezeMode) {
            return builtIn.name
        }
        if (4...6).contains(state.breezeMode) {
            let slot = Int(state.breezeMode - 4)
            return bluetooth.fanBreezeSlots[slot]?.name ?? "Custom Breeze"
        }
        return "Off"
    }

    @ViewBuilder
    private func breezeMenuLabel(_ name: String, selected: Bool) -> some View {
        Label(name, systemImage: selected ? "checkmark" : "wind")
    }

    private func selectCustomBreeze(_ preset: BreezePreset) {
        if let slot = bluetooth.fanBreezeSlots.firstIndex(where: { $0?.id == preset.id }) {
            if bluetooth.fanBreezeSlots[slot] == preset {
                bluetooth.setBreeze(UInt8(4 + slot))
            } else {
                bluetooth.installAndSelectBreeze(preset, slot: slot)
            }
        } else if bluetooth.supportsCustomBreezeSlots {
            pendingBreezePreset = preset
        }
    }

    private func breezeSlotInstallLabel(_ slot: Int) -> String {
        if let existing = bluetooth.fanBreezeSlots[slot] {
            return "Replace \(existing.name)"
        }
        return "Install in Empty Slot \(slot + 1)"
    }

    private var activeConnectionLabel: String {
        if bluetooth.isDeviceIOInProgress && connectionState == .ready {
            return "Updating"
        }
        switch connectionState {
        case .bluetoothUnavailable: return "Bluetooth Off"
        case .idle: return "Not Connected"
        case .scanning, .connecting: return "Connecting"
        case .discovering: return "Updating"
        case .ready: return "Connected"
        case .failed: return "Connection Failed"
        }
    }

    @ViewBuilder
    private var activeConnectionIndicator: some View {
        if bluetooth.isDeviceIOInProgress ||
            connectionState == .scanning ||
            connectionState == .connecting ||
            connectionState == .discovering {
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
        } else {
            switch connectionState {
            case .ready:
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            default:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        switch connectionState {
        case .bluetoothUnavailable:
            ContentUnavailableView(
                "Bluetooth Unavailable",
                systemImage: "bluetooth.slash",
                description: Text("Turn on Bluetooth to connect to this fan.")
            )

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    bluetooth.restartDeviceSessionFromUserTap(
                        deviceID: knownFan.deviceID,
                        name: knownFan.advertisedName
                    )
                }
            }

        case .scanning:
            connectionProgress("Looking for \(knownFan.name)…")

        case .connecting:
            connectionProgress("Connecting to \(knownFan.name)…")

        case .discovering:
            connectionProgress("Loading fan controls…")

        case .idle, .ready:
            connectionProgress("Connecting…")
        }
    }

    private func connectionProgress(_ message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func connectIfNeeded() {
        bluetooth.beginDeviceSession(
            deviceID: knownFan.deviceID,
            name: knownFan.advertisedName
        )
    }
}

struct ProMistTimerIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let remainingSeconds: UInt32
    let durationSeconds: UInt32

    private let timerOrange = Color(red: 1, green: 0.62, blue: 0.08)

    private var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, Double(remainingSeconds) / Double(durationSeconds)))
    }

    var body: some View {
        Group {
            if remainingSeconds == 0 {
                Image(systemName: "timer")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .foregroundStyle(.primary)
            } else {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let lineWidth = max(2, side * 0.12)

                    ZStack {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                timerOrange,
                                style: StrokeStyle(
                                    lineWidth: lineWidth,
                                    lineCap: .round
                                )
                            )
                            // Countdown begins at twelve o'clock and drains
                            // counter-clockwise toward its fixed leading edge.
                            .rotationEffect(.degrees(-90))

                        // The hand begins at twelve o'clock and follows the
                        // shrinking ring's trailing edge exactly.
                        ZStack {
                            Color.clear
                            Capsule()
                                .fill(timerOrange)
                                .frame(
                                    width: max(1.5, lineWidth * 0.65),
                                    height: side * 0.23
                                )
                                .offset(y: -side * 0.16)
                        }
                        .rotationEffect(.degrees(progress * 360))
                    }
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1),
                        value: remainingSeconds
                    )
                    .frame(width: side, height: side)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private func timerPresetLabel(_ minutes: Int) -> String {
    minutes == 60 ? "1 hour" : "\(minutes) minutes"
}

func timerRemainingLabel(_ seconds: UInt32) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    if minutes >= 60 { return "1 hr" }
    if minutes == 0 { return "\(remainder)s" }
    return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
}
