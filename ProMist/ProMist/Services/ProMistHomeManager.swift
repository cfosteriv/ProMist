// Apple Home association and Matter commissioning coordinator. Stable HomeKit
// UUIDs are persisted because names, rooms, and reachability are mutable metadata.
import Foundation
import HomeKit
import Matter
import Observation

enum ProMistHomeError: LocalizedError {
    case permissionDenied, insufficientPrivileges, noHome, accessoryNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Apple Home access was denied."
        case .insufficientPrivileges:
            "Apple Home rejected Matter setup privileges. Reinstall a build signed with the Matter Setup Payload capability and use a Home owner or administrator account."
        case .noHome: "Create a home in the Home app before adding ProMist."
        case .accessoryNotFound:
            "ProMist was added, but has not appeared in Apple Home yet."
        }
    }
}

struct ProMistHomeStatus: Equatable {
    var isInHome = false
    var isReachable = false
    var accessoryName: String?
}

struct ProMistHomeAccessory: Identifiable, Equatable {
    let id: UUID
    let homeID: UUID
    let name: String
    let homeName: String
    let isReachable: Bool
    let manufacturer: String
    let model: String
    let matterNodeID: UInt64?
}

/// Discovers ProMist accessories in Apple Home, starts Apple's Matter setup
/// flow, and keeps local accessory associations separate from BLE ownership.
@Observable
@MainActor
final class ProMistHomeManager: NSObject, HMHomeManagerDelegate {
    private static let supportedManufacturer = "Charles Foster"
    private static let supportedModel = "ProMist"
    private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = []
    private(set) var homes: [HMHome] = []
    private let accessorySetupManager = HMAccessorySetupManager()
    private var manager: HMHomeManager?

    init(startServices: Bool = true) {
        super.init()
        guard startServices else { return }
        manager = HMHomeManager()
        manager?.delegate = self
        refresh()
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { refresh() }
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) { refresh() }
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) { refresh() }

    func status(for fan: KnownFan) -> ProMistHomeStatus {
        guard let accessoryID = fan.homeAccessoryIdentifier else { return .init() }
        guard let accessory = homes.lazy.flatMap(\.accessories).first(where: {
            $0.uniqueIdentifier == accessoryID
        }) else { return .init() } // persisted link is stale
        return .init(
            isInHome: true,
            isReachable: accessory.isReachable,
            accessoryName: accessory.name
        )
    }

    func importableAccessories(excluding fans: [KnownFan]) -> [ProMistHomeAccessory] {
        let linkedIDs = Set(fans.compactMap(\.homeAccessoryIdentifier))
        return homes.flatMap { home in
            home.accessories.compactMap { accessory -> ProMistHomeAccessory? in
                guard !linkedIDs.contains(accessory.uniqueIdentifier),
                      isProMist(accessory),
                      accessory.services.contains(where: {
                          $0.serviceType == HMServiceTypeFan
                      }) else { return nil }
                return ProMistHomeAccessory(
                    id: accessory.uniqueIdentifier,
                    homeID: home.uniqueIdentifier,
                    name: accessory.name,
                    homeName: home.name,
                    isReachable: accessory.isReachable,
                    manufacturer: accessory.manufacturer ?? "",
                    model: accessory.model ?? "",
                    matterNodeID: accessory.matterNodeID
                )
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func associate(_ accessory: ProMistHomeAccessory, with fan: KnownFan) {
        fan.homeIdentifier = accessory.homeID
        fan.homeAccessoryIdentifier = accessory.id
        fan.matterNodeID = accessory.matterNodeID
        fan.isMatterCommissioned = true
    }

    private func isProMist(_ accessory: HMAccessory) -> Bool {
        guard let manufacturer = accessory.manufacturer,
              let model = accessory.model else { return false }
        return Self.supportedManufacturer.caseInsensitiveCompare(manufacturer) ==
            .orderedSame &&
            Self.supportedModel.caseInsensitiveCompare(model) == .orderedSame
    }

    /// Fails before the BLE handoff when Home access is unavailable, preserving
    /// the otherwise healthy proprietary session.
    func validateMatterSetupAccess() throws {
        guard authorizationStatus.contains(.authorized) else {
            throw ProMistHomeError.permissionDenied
        }
        guard !homes.isEmpty else { throw ProMistHomeError.noHome }
    }

    /// Hands an authenticated setup payload to Apple and associates the
    /// resulting Home accessory with the saved fan record.
    ///
    /// - Throws: Home authorization, setup, or accessory-discovery errors.
    func commission(_ fan: KnownFan, onboardingPayload: String) async throws {
        try validateMatterSetupAccess()

        let request = HMAccessorySetupRequest()
        request.suggestedAccessoryName = fan.name
        guard let matterPayload = MTRSetupPayload(payload: onboardingPayload) else {
            throw ProMistControlError.matterSetupUnavailable
        }
        request.matterPayload = matterPayload

        // Avoid an unnecessary home picker when only one Home exists. With
        // multiple homes, leaving this nil lets Apple's setup UI ask the user.
        if homes.count == 1 {
            request.homeUniqueIdentifier = homes[0].uniqueIdentifier
        }

        let result: HMAccessorySetupResult = try await withCheckedThrowingContinuation {
            continuation in
            accessorySetupManager.performAccessorySetup(using: request) { result, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == HMErrorDomain && nsError.code == 17 {
                        continuation.resume(
                            throwing: ProMistHomeError.insufficientPrivileges
                        )
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: ProMistHomeError.accessoryNotFound)
                }
            }
        }

        guard let accessoryID = result.accessoryUniqueIdentifiers.first else {
            throw ProMistHomeError.accessoryNotFound
        }
        fan.homeIdentifier = result.homeUniqueIdentifier
        fan.homeAccessoryIdentifier = accessoryID
        fan.isMatterCommissioned = true
        refresh()
    }

    func removeStaleAssociation(from fan: KnownFan) {
        guard !status(for: fan).isInHome else { return }
        // Association invariant: these values describe one local Home/Matter
        // representation and are either all current or all absent. The fan's
        // physical commissioning state is re-established by the next verified
        // Home import rather than retained as stale local metadata.
        fan.homeIdentifier = nil
        fan.homeAccessoryIdentifier = nil
        fan.matterNodeID = nil
        fan.isMatterCommissioned = false
    }

    private func refresh() {
        guard let manager else {
            authorizationStatus = []
            homes = []
            return
        }
        authorizationStatus = manager.authorizationStatus
        homes = manager.homes
    }
}
