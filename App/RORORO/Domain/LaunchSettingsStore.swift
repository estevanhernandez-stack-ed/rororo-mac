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
    /// Auto-keys safety config (Slope C, ADR 0004 Decision 9). Holds
    /// the user's kill-key + gesture choice + resume grace. Default is
    /// F19 + hold-1s + 5s grace; the recorder lets the user record any
    /// other key and toggle hold/double-tap during setup.
    @Published public private(set) var autoKeysSafety: AutoKeysSafetyConfig
    /// When true, the cycler synthesizes `[spacebar, 1s]` for each
    /// running account at runtime and uses `stayAwakeLoopDelay` (30 s)
    /// instead of `autoKeysLoopDelay`. Saved per-account `autoKeys`
    /// values are NOT touched — toggling this off restores everyone to
    /// their custom macros immediately. Mode, not destructive preset.
    @Published public private(set) var autoKeysStayAwakeMode: Bool

    /// Default cycle pacing — 0 means "as soon as the cycle finishes
    /// the last account, start back at the first." That's the natural
    /// fit for active-macro use (firing keybinds repeatedly while AFK).
    public static let defaultAutoKeysLoopDelay: TimeInterval = 0
    /// Loop delay used when stay-awake mode is active. 30 s gives the
    /// user a clear visual rhythm — burst through the windows, pause
    /// long enough to come back, repeat.
    public static let stayAwakeLoopDelay: TimeInterval = 30
    /// Time the cycler holds focus on each window in stay-awake mode
    /// before advancing to the next. 1 s is long enough to actually
    /// see the window flip and the avatar jump.
    public static let stayAwakeStepDelay: TimeInterval = 1.0

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
        if let raw = defaults.data(forKey: Keys.autoKeysSafety),
           let decoded = try? JSONDecoder().decode(AutoKeysSafetyConfig.self, from: raw) {
            self.autoKeysSafety = decoded
        } else {
            self.autoKeysSafety = .default
        }
        self.autoKeysStayAwakeMode = defaults.bool(forKey: Keys.autoKeysStayAwakeMode)
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

    /// Set the cycler loop delay (Slope C). Clamped to a sane upper
    /// bound (`CycleBudget.hardCap` — past that, the first account's
    /// AFK timer would fire before the cycle returns). Lower bound is
    /// 0 — the cycler treats that as back-to-back iterations, which
    /// is the natural fit for active-macro use. Stay-awake-only mode
    /// is the case where you'd want a non-zero delay (e.g.
    /// `LaunchSettingsStore.stayAwakeLoopDelay = 14 * 60`).
    public func setAutoKeysLoopDelay(_ value: TimeInterval) {
        let clamped = max(0, min(value, CycleBudget.hardCap))
        autoKeysLoopDelay = clamped
        defaults.set(clamped, forKey: Keys.autoKeysLoopDelay)
    }

    /// Toggle stay-awake mode. Non-destructive — flipping the flag
    /// changes how the cycler synthesizes targets at runtime; saved
    /// per-account macros remain on disk untouched.
    public func setAutoKeysStayAwakeMode(_ on: Bool) {
        autoKeysStayAwakeMode = on
        defaults.set(on, forKey: Keys.autoKeysStayAwakeMode)
    }

    /// Persist the safety config (Slope C, ADR 0004 Decision 9). The
    /// recorder writes this when the user picks their kill key + gesture.
    public func setAutoKeysSafety(_ config: AutoKeysSafetyConfig) {
        autoKeysSafety = config
        if let encoded = try? JSONEncoder().encode(config) {
            defaults.set(encoded, forKey: Keys.autoKeysSafety)
        }
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
        static let autoKeysSafety = "rororo.autoKeys.safety"
        static let autoKeysStayAwakeMode = "rororo.autoKeys.stayAwakeMode"
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
