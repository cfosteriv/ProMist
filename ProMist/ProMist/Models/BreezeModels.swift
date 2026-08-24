import CoreBluetooth
import Foundation
import Observation

struct BreezeKeyframe: Codable, Equatable, Hashable, Sendable {
    var second: Int
    var level: Int
}

struct BreezePreset: Codable, Equatable, Identifiable, Sendable {
    static let allowedCycleSeconds = [15, 30, 45, 60]
    static let maximumKeyframes = 16

    var id: UInt32
    var name: String
    var cycleSeconds: Int
    var keyframes: [BreezeKeyframe]

    static func fresh() -> BreezePreset {
        BreezePreset(
            id: UInt32.random(in: 1...UInt32.max),
            name: "",
            cycleSeconds: 30,
            keyframes: [
                BreezeKeyframe(second: 0, level: 3),
                BreezeKeyframe(second: 10, level: 5),
                BreezeKeyframe(second: 20, level: 3)
            ]
        )
    }

    var normalizedKeyframes: [BreezeKeyframe] {
        var bySecond: [Int: BreezeKeyframe] = [:]
        for frame in keyframes {
            let second = min(max(frame.second, 0), cycleSeconds - 1)
            bySecond[second] = BreezeKeyframe(
                second: second,
                level: min(max(frame.level, 1), 5)
            )
        }
        if bySecond[0] == nil {
            bySecond[0] = BreezeKeyframe(second: 0, level: 3)
        }
        return bySecond.values.sorted { $0.second < $1.second }
            .prefix(Self.maximumKeyframes).map { $0 }
    }

    var validationMessage: String? {
        guard Self.allowedCycleSeconds.contains(cycleSeconds) else {
            return "Choose a 15, 30, 45, or 60 second cycle."
        }
        let utf8Count = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .utf8.count
        guard utf8Count > 0, utf8Count <= 20 else {
            return "Names must contain 1–20 UTF-8 bytes."
        }
        let frames = normalizedKeyframes
        guard !frames.isEmpty, frames.count <= Self.maximumKeyframes else {
            return "A breeze can contain at most 16 points."
        }
        for index in frames.indices {
            let next = frames[(index + 1) % frames.count]
            if abs(frames[index].level - next.level) > 2 {
                return "Adjacent power levels—including the loop boundary—may differ by at most two steps."
            }
        }
        return nil
    }

    var segments: [(level: UInt8, duration: UInt8)] {
        let frames = normalizedKeyframes
        return frames.indices.map { index in
            let nextSecond = index + 1 < frames.count
                ? frames[index + 1].second
                : cycleSeconds
            return (
                UInt8(frames[index].level),
                UInt8(nextSecond - frames[index].second)
            )
        }
    }
}

enum BuiltInBreeze: UInt8, CaseIterable, Identifiable {
    case windyDay = 1
    case highsAndLows = 2
    case lowsAndHighs = 3

    var id: UInt8 { rawValue }
    var name: String {
        switch self {
        case .windyDay: "Windy Day"
        case .highsAndLows: "Highs and Lows"
        case .lowsAndHighs: "Lows and Highs"
        }
    }
}

@Observable
@MainActor
final class BreezeLibrary {
    private static let storageKey = "ProMistCustomBreezeLibraryV1"
    private(set) var presets: [BreezePreset] = []
    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([BreezePreset].self, from: data) {
            presets = decoded
        }
    }

    func save(_ preset: BreezePreset) {
        guard validationMessage(for: preset) == nil else { return }
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func validationMessage(for preset: BreezePreset) -> String? {
        if let message = preset.validationMessage {
            return message
        }

        let candidate = normalizedName(preset.name)
        let conflictsWithBuiltIn = BuiltInBreeze.allCases.contains {
            normalizedName($0.name) == candidate
        }
        let conflictsWithCustom = presets.contains {
            $0.id != preset.id && normalizedName($0.name) == candidate
        }
        if conflictsWithBuiltIn || conflictsWithCustom {
            return "Choose a unique breeze name."
        }
        return nil
    }

    func delete(_ preset: BreezePreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func reset() {
        presets.removeAll()
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

extension ProMistBLEProtocol {
    static let breezeProfileWireSize = 64

    static func breezeProfile(_ preset: BreezePreset?, slot: Int) -> Data? {
        guard (0..<3).contains(slot) else { return nil }
        var bytes = Data(repeating: 0, count: breezeProfileWireSize)
        bytes[0] = version
        bytes[1] = UInt8(slot)
        if let preset {
            guard preset.validationMessage == nil else { return nil }
            let name = Data(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            let segments = preset.segments
            bytes[2] = 1
            bytes[3] = UInt8(name.count)
            bytes[4] = UInt8(segments.count)
            bytes[5] = UInt8(preset.cycleSeconds)
            bytes.replaceSubrange(6..<10, with: preset.id.littleEndianData)
            bytes.replaceSubrange(10..<(10 + name.count), with: name)
            for (index, segment) in segments.enumerated() {
                bytes[30 + index * 2] = segment.level
                bytes[31 + index * 2] = segment.duration
            }
        }
        let crc = breezeCRC16(bytes.prefix(62))
        bytes[62] = UInt8(crc & 0xff)
        bytes[63] = UInt8(crc >> 8)
        return bytes
    }

    static func breezeProfile(_ data: Data) -> (slot: Int, preset: BreezePreset?)? {
        guard data.count == breezeProfileWireSize, data[0] == version,
              data[1] < 3, data[2] <= 1, data[3] <= 20, data[4] <= 16,
              let storedCRC: UInt16 = data.integer(at: 62),
              storedCRC == breezeCRC16(data.prefix(62)) else { return nil }
        let slot = Int(data[1])
        guard data[2] == 1 else { return (slot, nil) }
        guard data[3] > 0, data[4] > 0,
              let id: UInt32 = data.integer(at: 6), id != 0,
              let name = String(data: data[10..<(10 + Int(data[3]))], encoding: .utf8)
        else { return nil }
        var second = 0
        var frames: [BreezeKeyframe] = []
        for index in 0..<Int(data[4]) {
            let level = Int(data[30 + index * 2])
            let duration = Int(data[31 + index * 2])
            guard (1...5).contains(level), duration > 0 else { return nil }
            frames.append(BreezeKeyframe(second: second, level: level))
            second += duration
        }
        let preset = BreezePreset(
            id: id,
            name: name,
            cycleSeconds: Int(data[5]),
            keyframes: frames
        )
        guard second == preset.cycleSeconds, preset.validationMessage == nil else {
            return nil
        }
        return (slot, preset)
    }

    private static func breezeCRC16<S: Sequence>(_ bytes: S) -> UInt16
    where S.Element == UInt8 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
