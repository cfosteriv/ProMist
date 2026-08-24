// Saved-device overview. Tiles prefer live observable state and fall back to
// explicitly labeled persisted snapshots when a fan is not connected.
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    @Query(sort: \KnownFan.lastConnectedAt, order: .reverse)
    private var knownFans: [KnownFan]
    @Binding var selectedFan: KnownFan?
    @Binding var showingFanPicker: Bool
    @Binding var showingSettings: Bool
    @State private var pendingExpansionDeviceID: UInt64?

    var body: some View {
        Group {
            if knownFans.isEmpty {
                emptyDashboard
            } else {
                fanTiles
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") {
                    showingSettings = true
                }
            }
            if !knownFans.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Fan", systemImage: "plus") {
                        showingFanPicker = true
                    }
                }
            }
        }
        .onChange(of: bluetooth.connectionState) { _, state in
            guard let pendingExpansionDeviceID else { return }
            if state == .ready,
               bluetooth.deviceState.deviceID == pendingExpansionDeviceID,
               let fan = knownFans.first(where: {
                   $0.deviceID == pendingExpansionDeviceID
               }) {
                self.pendingExpansionDeviceID = nil
                withAnimation(.snappy) {
                    selectedFan = fan
                }
            } else if case .failed = state {
                self.pendingExpansionDeviceID = nil
            }
        }
    }

    private var emptyDashboard: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "fan")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Button("Connect") {
                showingFanPicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Add a nearby ProMist fan to get started.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fanTiles: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                spacing: 16
            ) {
                ForEach(knownFans) { fan in
                    FanDisclosureCard(
                        fan: fan,
                        isExpanded: expansionBinding(for: fan)
                    )
                }
            }
            .padding()
        }
    }

    private func expansionBinding(for fan: KnownFan) -> Binding<Bool> {
        Binding(
            get: { selectedFan === fan },
            set: { expanded in
                if expanded {
                    guard fan.hasBLEIdentity else { return }
                    let state = bluetooth.connectionState(
                        forDeviceID: fan.deviceID,
                        peripheralIdentifier: fan.peripheralIdentifier
                    )
                    guard state == .ready else {
                        pendingExpansionDeviceID = fan.deviceID
                        switch state {
                        case .scanning, .connecting:
                            bluetooth.restartDeviceSessionFromUserTap(
                                deviceID: fan.deviceID,
                                name: fan.advertisedName
                            )
                        case .bluetoothUnavailable, .idle, .discovering, .failed:
                            bluetooth.beginDeviceSession(
                                deviceID: fan.deviceID,
                                name: fan.advertisedName
                            )
                        case .ready:
                            break
                        }
                        return
                    }
                    pendingExpansionDeviceID = nil
                } else if pendingExpansionDeviceID == fan.deviceID {
                    pendingExpansionDeviceID = nil
                }
                withAnimation(.snappy) {
                    selectedFan = expanded ? fan : nil
                }
            }
        )
    }
}

private struct FanDisclosureCard: View {
    private let settingsActionWidth: CGFloat = 80

    let fan: KnownFan
    @Binding var isExpanded: Bool
    @State private var showingDeviceSettings = false
    @State private var restingSwipeOffset: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            if !isExpanded {
                settingsAction
            }

            cardContent
                .offset(x: displayedSwipeOffset)
                .gesture(swipeGesture, including: isExpanded ? .none : .all)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $showingDeviceSettings) {
            DeviceSettingsView(knownFan: fan) {
                isExpanded = false
                restingSwipeOffset = 0
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                restingSwipeOffset = 0
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityAction(named: "Device settings") {
            showingDeviceSettings = true
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            FanTileSummary(fan: fan, isExpanded: $isExpanded)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .background.secondary,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
    }

    private var settingsAction: some View {
        Button {
            withAnimation(.snappy) {
                restingSwipeOffset = 0
            }
            showingDeviceSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 56, height: 56)
                .foregroundStyle(.white)
                .frame(maxHeight: .infinity)
                .background(
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .frame(width: settingsActionWidth)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Device settings for \(fan.name)")
    }

    private var displayedSwipeOffset: CGFloat {
        min(0, max(-settingsActionWidth, restingSwipeOffset + dragTranslation))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dragTranslation) { value, translation, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                translation = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                let projectedOffset = restingSwipeOffset +
                    value.predictedEndTranslation.width
                withAnimation(.snappy) {
                    restingSwipeOffset = projectedOffset < -settingsActionWidth / 2
                        ? -settingsActionWidth
                        : 0
                }
            }
    }
}

private struct FanTileSummary: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    let fan: KnownFan
    @Binding var isExpanded: Bool

    private var connectionState: ProMistConnectionState {
        guard fan.hasBLEIdentity else { return .idle }
        return bluetooth.connectionState(
            forDeviceID: fan.deviceID,
            peripheralIdentifier: fan.peripheralIdentifier
        )
    }

    private var isAddingToHome: Bool {
        bluetooth.isMatterCommissioningHandoff &&
            bluetooth.requestedDeviceID == fan.deviceID
    }

    private var isVisuallyExpanded: Bool {
        isExpanded && connectionState == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                guard fan.hasBLEIdentity else { return }
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "fan")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(fan.name)
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 6) {
                        connectionIndicator
                        Text(connectionLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isVisuallyExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!fan.hasBLEIdentity)

            if isVisuallyExpanded {
                DeviceView(knownFan: fan) {
                    isExpanded = false
                }
            } else {
                Divider()
                collapsedStatus
            }
        }
        .contentShape(Rectangle())
        .accessibilityValue(isVisuallyExpanded ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private var collapsedStatus: some View {
        if fan.isHomeOnly {
            Label("Apple Home only", systemImage: "house.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let snapshot = bluetooth.sessionSnapshot(for: fan.deviceID) {
            let state = snapshot.state
            HStack(spacing: 16) {
                Image(systemName: state.power ? "power" : "power.dotted")
                    .foregroundStyle(state.power ? .green : .primary)

                if state.power {
                    if state.breezeMode == 0 {
                        Text("\(fanDutyPercent(for: state))%")
                    } else {
                        Image(systemName: "wind")
                            .accessibilityLabel("Breeze on")
                    }

                    if state.mistMode != 0 {
                        Image(systemName: "drop.fill")
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Mist on")
                    }

                    if state.oscillationMode != 0 {
                        Image(systemName: "fan.oscillation")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Oscillation on")
                    }

                    if state.timerRemainingSeconds > 0 {
                        HStack(spacing: 4) {
                            ProMistTimerIndicator(
                                remainingSeconds: state.timerRemainingSeconds,
                                durationSeconds: state.timerDurationSeconds
                            )
                            .frame(width: 22, height: 22)
                            Text(timerRemainingLabel(state.timerRemainingSeconds))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Timer")
                        .accessibilityValue(
                            "\(timerRemainingLabel(state.timerRemainingSeconds)) remaining"
                        )
                    }

                    Spacer()

                    if state.fault != 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.subheadline)
            .accessibilityLabel("Last known status from this app session")
        } else {
            Label("No recent status", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func fanDutyPercent(for state: ProMistDeviceState) -> Int {
        25 + (Int(state.fanSpeed) - 1) * 15
    }

    private var connectionLabel: String {
        if fan.isHomeOnly { return "Home Only" }
        if isAddingToHome { return "Adding to Home" }
        return switch connectionState {
        case .bluetoothUnavailable: "Bluetooth Off"
        case .idle: "Disconnected"
        case .scanning, .connecting: "Connecting"
        case .discovering: "Updating"
        case .ready: "Connected"
        case .failed: "Connection Failed"
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        if isAddingToHome {
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
        } else {
            switch connectionState {
            case .scanning, .connecting, .discovering:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)

            case .bluetoothUnavailable, .idle, .failed:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)

            case .ready:
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }
        }
    }
}
