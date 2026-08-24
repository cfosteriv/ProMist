// Human-readable projection of bounded structured firmware diagnostics. Event
// payloads remain numeric and redacted on-device so this view cannot expose keys.
import SwiftUI

enum DiagnosticCategory: Hashable {
    case fanSpeed
    case mist
    case rotation

    var title: String {
        switch self {
        case .fanSpeed: "Fan Speed"
        case .mist: "Mist"
        case .rotation: "Rotation"
        }
    }

    var systemImage: String {
        switch self {
        case .fanSpeed: "fan.fill"
        case .mist: "drop.fill"
        case .rotation: "fan.oscillation"
        }
    }

    var component: UInt8 {
        switch self {
        case .fanSpeed: 3
        case .rotation: 4
        case .mist: 5
        }
    }
}

struct DiagnosticsView: View {
    @Environment(ProMistBLECentral.self) private var bluetooth
    let category: DiagnosticCategory

    private var records: [ProMistDiagnostic] {
        Array(
            bluetooth.diagnostics
                .filter { $0.component == category.component }
                .reversed()
        )
    }

    var body: some View {
        List(records) { record in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(eventName(record.eventID))
                        .font(.headline)
                    Spacer()
                    Text(severityName(record.severity))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(severityColor(record.severity))
                }
                Text(
                    "Record \(record.sequence) • \(formattedUptime(record.uptimeMilliseconds)) after startup"
                )
                .foregroundStyle(.secondary)
                Text("Values: \(record.first), \(record.second)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.vertical, 3)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                dimensions.width
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No \(category.title) Diagnostics",
                    systemImage: category.systemImage,
                    description: Text("No stored events were reported by this fan.")
                )
            }
        }
        .navigationTitle(category.title)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                bluetooth.refreshDiagnostics()
            }
        }
        .task { bluetooth.refreshDiagnostics() }
    }

    private func eventName(_ eventID: UInt16) -> String {
        switch eventID {
        case 200: "Target and observed speed differed"
        case 201: "Fan motor failed to start"
        case 300: "Passive rotation home search"
        case 301: "Rotation safety fault"
        case 400: "Mist controller fault"
        default: "Event \(eventID)"
        }
    }

    private func severityName(_ severity: UInt8) -> String {
        switch severity {
        case 0: "Debug"
        case 1: "Info"
        case 2: "Warning"
        case 3: "Error"
        default: "Critical"
        }
    }

    private func severityColor(_ severity: UInt8) -> Color {
        switch severity {
        case 0, 1: .secondary
        case 2: .orange
        default: .red
        }
    }

    private func formattedUptime(_ milliseconds: UInt32) -> String {
        let seconds = Double(milliseconds) / 1_000
        return seconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }
}
