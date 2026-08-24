// App Intent entity projection. This small UserDefaults-backed index lets Siri
// resolve saved fans without coupling the intent process to SwiftData UI state.
import AppIntents
import Foundation

struct ProMistDeviceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "ProMist")
    static let defaultQuery = ProMistDeviceQuery()
    let id: String
    var deviceID: UInt64 { UInt64(id, radix: 16) ?? 0 }
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "ID \(id.uppercased())") }
}

struct ProMistDeviceQuery: EntityQuery {
    /// Resolves only requested identifiers that still exist in the saved index.
    /// - Parameter identifiers: Lowercase hexadecimal firmware device IDs.
    /// - Returns: Matching entities in saved-device order; unknown IDs are omitted.
    func entities(for identifiers: [String]) async throws -> [ProMistDeviceEntity] {
        savedDevices().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ProMistDeviceEntity] { savedDevices() }

    func defaultResult() async -> ProMistDeviceEntity? { savedDevices().first }

    /// Converts the intentionally minimal property-list index into intent entities.
    /// Malformed records are ignored because an intent should never surface a
    /// partially written device as a selectable target.
    private func savedDevices() -> [ProMistDeviceEntity] {
        let records = UserDefaults.standard.array(forKey: "ProMistIntentDevices") as? [[String: Any]] ?? []
        return records.compactMap { record in
            guard let id = record["id"] as? NSNumber, let name = record["name"] as? String else { return nil }
            return .init(id: String(id.uint64Value, radix: 16), name: name)
        }
    }
}
