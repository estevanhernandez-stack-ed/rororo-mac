// LaunchSettingsStore.swift
// Domain — what RORORO writes to Roblox's settings files at launch time.
//
// Two writers fire on each launch:
//   - GlobalSettingsWriter → `~/Library/Roblox/GlobalBasicSettings_*.xml`
//     (FramerateCap; Roblox-wide, multi-instance shares it uniformly)
//   - ClientSettingsWriter → `<bundle>/Contents/MacOS/ClientSettings/
//     ClientAppSettings.json` (FFlag dictionary)
//
// This store holds the desired values + the policy switches. Persisted
// via UserDefaults so settings survive app restarts. UI lands in a later
// phase (A3 in the slope plan); for now values are set programmatically.
//
// Defaults are no-op: framerate cap nil (don't touch the XML), flags
// empty (don't touch the JSON). Until the user opts in, RORORO's launch
// flow is byte-identical to its prior behavior.

import Foundation

@MainActor
public final class LaunchSettingsStore: ObservableObject {

    public static let shared = LaunchSettingsStore()

    private let defaults: UserDefaults

    @Published public private(set) var framerateCap: Int?
    @Published public private(set) var fflags: [String: AnyCodableValue]
    /// Cycler loop delay in seconds (Slope C). The pause that the
    /// cycler observes between completing one full pass over all
    /// configured accounts and starting the next. Default `14 * 60`
    /// (840s = 14 min) — sits comfortably under Roblox's ~20-minute
    /// AFK timer with budget left over for `CycleBudget.warnThreshold`
    /// (18 min) before the user has to trim sequences. See ADR 0004.
    @Published public private(set) var autoKeysLoopDelay: TimeInterval

    public static let defaultAutoKeysLoopDelay: TimeInterval = 14 * 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cap = defaults.object(forKey: Keys.framerateCap) as? Int
        self.framerateCap = cap
        if let raw = defaults.data(forKey: Keys.fflags),
           let decoded = try? JSONDecoder().decode([String: AnyCodableValue].self, from: raw) {
            self.fflags = decoded
        } else {
            self.fflags = [:]
        }
        if defaults.object(forKey: Keys.autoKeysLoopDelay) != nil {
            self.autoKeysLoopDelay = defaults.double(forKey: Keys.autoKeysLoopDelay)
        } else {
            self.autoKeysLoopDelay = Self.defaultAutoKeysLoopDelay
        }
    }

    public func setFramerateCap(_ value: Int?) {
        framerateCap = value
        if let value {
            defaults.set(value, forKey: Keys.framerateCap)
        } else {
            defaults.removeObject(forKey: Keys.framerateCap)
        }
    }

    public func setFFlags(_ flags: [String: AnyCodableValue]) {
        fflags = flags
        if flags.isEmpty {
            defaults.removeObject(forKey: Keys.fflags)
        } else if let encoded = try? JSONEncoder().encode(flags) {
            defaults.set(encoded, forKey: Keys.fflags)
        }
    }

    /// Set the cycler loop delay (Slope C). Clamped to a sane range —
    /// Roblox's AFK timer wants ≤ 18 min per window (`CycleBudget.warnThreshold`),
    /// and a delay of 0 still works (the cycler treats it as back-to-back
    /// passes). The minimum 30 s prevents a user from accidentally
    /// pegging a CPU on a tight loop.
    public func setAutoKeysLoopDelay(_ value: TimeInterval) {
        let clamped = max(30, min(value, CycleBudget.hardCap))
        autoKeysLoopDelay = clamped
        defaults.set(clamped, forKey: Keys.autoKeysLoopDelay)
    }

    /// Snapshot of current settings — used by the launcher to apply at
    /// launch time without holding a reference to the store on a non-main
    /// actor.
    public func snapshot() -> Snapshot {
        Snapshot(framerateCap: framerateCap, fflags: fflags)
    }

    public struct Snapshot: Sendable, Equatable {
        public let framerateCap: Int?
        public let fflags: [String: AnyCodableValue]
    }

    private enum Keys {
        static let framerateCap = "rororo.launch.framerateCap"
        static let fflags = "rororo.launch.fflags"
        static let autoKeysLoopDelay = "rororo.autoKeys.loopDelay"
    }
}

/// JSON-encodable wrapper for Roblox FFlag values. Roblox accepts
/// bool / number / string at the wire level; this wrapper preserves
/// the type through round-trips.
public enum AnyCodableValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "AnyCodableValue: unsupported scalar type"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    /// Convert to a JSONSerialization-compatible value (Foundation types).
    /// Used when the snapshot crosses into ClientSettingsWriter, which
    /// builds [String: Any] for JSONSerialization.
    public var jsonObject: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }
}
