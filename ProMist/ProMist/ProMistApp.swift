// Application composition root. Long-lived Bluetooth and HomeKit coordinators
// are injected once so views and App Intents observe the same runtime owners.

import SwiftUI
import SwiftData
import AppIntents

@main
struct ProMistApp: App {
    @State private var bluetooth: ProMistBLECentral
    @State private var home: ProMistHomeManager
    @State private var breezeLibrary: BreezeLibrary
    private let uiTestProfile: ProMistUITestProfile?

    init() {
#if DEBUG
        let profile = ProMistUITestProfile.processArguments
        uiTestProfile = profile
        _bluetooth = State(initialValue: profile.map {
            ProMistBLECentral.uiTest(features: $0.features)
        } ?? ProMistBLECentral.shared)
        _home = State(initialValue: ProMistHomeManager(
            startServices: profile == nil
        ))
        _breezeLibrary = State(initialValue: BreezeLibrary())
#else
        uiTestProfile = nil
        _bluetooth = State(initialValue: ProMistBLECentral.shared)
        _home = State(initialValue: ProMistHomeManager())
        _breezeLibrary = State(initialValue: BreezeLibrary())
#endif
        ProMistAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .environment(bluetooth)
                .environment(home)
                .environment(breezeLibrary)
                .task {
                    await ProMistControlRegistry.shared.install(
                        bluetooth.deviceSessionCoordinator
                    )
                }
        }
        .modelContainer(for: KnownFan.self)
    }

    @ViewBuilder
    private var rootContent: some View {
#if DEBUG
        if let uiTestProfile {
            ProMistUITestRootView(profile: uiTestProfile)
        } else {
            ContentView()
        }
#else
        ContentView()
#endif
    }
}

private enum ProMistUITestProfile: String {
    case disconnected
    case full
    case noMist
    case basicOscillationOnly
    case noDiagnostics

    var features: ProMistFeatureSet {
        switch self {
        case .disconnected, .full:
            .currentDevice
        case .noMist:
            .currentDevice.subtracting(.mist)
        case .basicOscillationOnly:
            .currentDevice.subtracting(.positioning)
        case .noDiagnostics:
            .currentDevice.subtracting(.diagnostics)
        }
    }

    static var processArguments: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ProMistUITestMode") else { return nil }
        guard let option = arguments.firstIndex(of: "-ProMistCapabilities"),
              arguments.indices.contains(option + 1),
              let profile = Self(rawValue: arguments[option + 1]) else {
            return .disconnected
        }
        return profile
    }
}

#if DEBUG
private struct ProMistUITestRootView: View {
    let profile: ProMistUITestProfile
    private let knownFan = KnownFan(
        deviceID: 1,
        name: "UI Test ProMist"
    )

    var body: some View {
        NavigationStack {
            Group {
                if profile == .disconnected {
                    VStack(spacing: 18) {
                        Image(systemName: "fan")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Button("Connect") {}
                            .buttonStyle(.borderedProminent)
                        Text("Add a nearby ProMist fan to get started.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("initial-device-setup")
                } else {
                    ScrollView {
                        DeviceView(knownFan: knownFan)
                            .padding()
                    }
                }
            }
            .navigationTitle(profile == .disconnected ? "Devices" : knownFan.name)
        }
        .accessibilityIdentifier("promist-root")
    }
}
#endif
