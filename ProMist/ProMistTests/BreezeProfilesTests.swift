import Foundation
import Testing
@testable import ProMist

@MainActor
struct BreezeProfilesTests {
    @Test func profileRoundTripsThroughFixedWireRecord() throws {
        let preset = BreezePreset(
            id: 0x1234_5678,
            name: "Porch Wave",
            cycleSeconds: 15,
            keyframes: [
                BreezeKeyframe(second: 0, level: 3),
                BreezeKeyframe(second: 5, level: 5),
                BreezeKeyframe(second: 10, level: 3)
            ]
        )
        let data = try #require(ProMistBLEProtocol.breezeProfile(preset, slot: 1))
        #expect(data.count == 64)
        let decoded = try #require(ProMistBLEProtocol.breezeProfile(data))
        #expect(decoded.slot == 1)
        #expect(decoded.preset == preset)
    }

    @Test func checksumAndUnsafeTransitionsAreRejected() throws {
        var preset = BreezePreset.fresh()
        preset.name = "Unsafe"
        preset.keyframes = [
            BreezeKeyframe(second: 0, level: 1),
            BreezeKeyframe(second: 10, level: 5),
            BreezeKeyframe(second: 20, level: 1)
        ]
        #expect(preset.validationMessage != nil)
        #expect(ProMistBLEProtocol.breezeProfile(preset, slot: 0) == nil)

        var good = BreezePreset.fresh()
        good.name = "Good Breeze"
        var data = try #require(ProMistBLEProtocol.breezeProfile(good, slot: 0))
        data[31] ^= 1
        #expect(ProMistBLEProtocol.breezeProfile(data) == nil)
    }

    @Test func emptySlotRoundTrips() throws {
        let data = try #require(ProMistBLEProtocol.breezeProfile(nil, slot: 2))
        let decoded = try #require(ProMistBLEProtocol.breezeProfile(data))
        #expect(decoded.slot == 2)
        #expect(decoded.preset == nil)
    }

    @Test func newPresetsRequireAUniqueName() throws {
        let suiteName = "BreezeProfilesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = BreezeLibrary(userDefaults: defaults)

        var unnamed = BreezePreset.fresh()
        #expect(unnamed.name.isEmpty)
        #expect(library.validationMessage(for: unnamed) != nil)

        unnamed.name = "Evening Wave"
        #expect(library.validationMessage(for: unnamed) == nil)
        library.save(unnamed)

        var duplicate = BreezePreset.fresh()
        duplicate.name = "  EVENING WAVE  "
        #expect(library.validationMessage(for: duplicate) == "Choose a unique breeze name.")
        library.save(duplicate)
        #expect(library.presets.count == 1)

        duplicate.name = "windy day"
        #expect(library.validationMessage(for: duplicate) == "Choose a unique breeze name.")
    }
}
