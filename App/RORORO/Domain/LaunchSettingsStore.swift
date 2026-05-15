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
    /// The active FFlag preset (ADR 0011), or nil for "no preset — only
    /// the user's `fflags` overrides apply." Replaces the pre-0011
    /// `lowResourceMode: Bool` toggle. At launch FFlagPresetLibrary
    /// .effectiveFlags merges the preset's bundle with `fflags`; user
    /// values win on overlap. Hyperion may silently no-op some bundle
    /// entries — bench actual deltas before trusting.
    @Published public private(set) var activePreset: FFlagPresetID?
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
    /// Global hotkey that arms / fires / stops the D-3 recorder
    /// (D-3.4.1). Default Ctrl+Opt+Shift+P — a 4-key chord with
    /// effectively zero collision risk against Roblox keybinds or
    /// macOS system shortcuts. User rebinds via the V2 sheet's
    /// "Change" affordance. Reusing `KillKeyCombo` because the shape
    /// is identical (keyCode + modifier bitmask).
    @Published public private(set) var recorderHotkey: KillKeyCombo
    /// Global fallback macro for accounts without their own recording
    /// and without an explicit sharing reference (D-3.8). Custom
    /// recordings + explicit references still win — this is only the
    /// third tier of the resolver waterfall. Coexists with the
    /// existing stay-awake override toggle; stay-awake wins when both
    /// are configured.
    @Published public private(set) var defaultMacroBehavior: DefaultMacroBehavior

    /// Default cycle pacing — 0 means "as soon as the cycle finishes
    /// the last account, start back at the first." That's the natural
    /// fit for active-macro use (firing keybinds repeatedly while AFK).
    public static let defaultAutoKeysLoopDelay: TimeInterval = 0
    /// Default recorder hotkey — Control+Option+Shift+P (D-3.4.1).
    /// `P` is virtual keyCode 35. Modifier bits: control (1<<18) |
    /// option (1<<19) | shift (1<<17). User-rebindable; the chord
    /// must include at least one modifier in practice to avoid
    /// accidental keystrokes triggering record/stop.
    public static let defaultRecorderHotkey = KillKeyCombo(
        keyCode: 35,
        modifiers: (1 << 17) | (1 << 18) | (1 << 19)
    )
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
        if let raw = defaults.data(forKey: Keys.recorderHotkey),
           let decoded = try? JSONDecoder().decode(KillKeyCombo.self, from: raw) {
            self.recorderHotkey = decoded
        } else {
            self.recorderHotkey = Self.defaultRecorderHotkey
        }
        if let raw = defaults.data(forKey: Keys.defaultMacroBehavior),
           let decoded = try? JSONDecoder().decode(DefaultMacroBehavior.self, from: raw) {
            self.defaultMacroBehavior = decoded
        } else {
            self.defaultMacroBehavior = .skip
        }
        // Migrate the legacy `lowResourceMode` bool → `activePreset` enum
        // (ADR 0011). A user who had low-resource mode ON keeps it as
        // activePreset == .lowResource; the old key is cleared so the
        // migration runs exactly once. If the new key is already present,
        // it wins and no migration is needed.
        if let raw = defaults.string(forKey: Keys.activePreset),
           let decoded = FFlagPresetID(rawValue: raw) {
            self.activePreset = decoded
        } else if defaults.bool(forKey: Keys.lowResourceMode) {
            self.activePreset = .lowResource
            defaults.set(FFlagPresetID.lowResource.rawValue, forKey: Keys.activePreset)
            defaults.removeObject(forKey: Keys.lowResourceMode)
        } else {
            self.activePreset = nil
            defaults.removeObject(forKey: Keys.lowResourceMode)
        }
        // Clean up any leftover P2.5 launch-size key from prior testing.
        // P2.5 was retracted — StartScreenSize is not the lever Roblox
        // uses for its hardcoded 800x600 player window floor.
        defaults.removeObject(forKey: "rororo.launch.startScreenSize")
    }

    /// Set the active FFlag preset (ADR 0011). Persisted across launches.
    /// At launch FFlagPresetLibrary.effectiveFlags merges the preset's
    /// bundle with the user's `fflags` overrides — user values win on
    /// overlap. Pass nil to clear the preset.
    public func setActivePreset(_ id: FFlagPresetID?) {
        activePreset = id
        if let id {
            defaults.set(id.rawValue, forKey: Keys.activePreset)
        } else {
            defaults.removeObject(forKey: Keys.activePreset)
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

    /// Persist the recorder hotkey (D-3.4.1). The V2 sheet writes this
    /// when the user picks a new chord via the "Change" affordance.
    public func setRecorderHotkey(_ combo: KillKeyCombo) {
        recorderHotkey = combo
        if let encoded = try? JSONEncoder().encode(combo) {
            defaults.set(encoded, forKey: Keys.recorderHotkey)
        }
    }

    /// Persist the global default macro behavior (D-3.8). The cycler
    /// toolbar picker writes this when the user picks Skip / Stay
    /// alive / Use [Account].
    public func setDefaultMacroBehavior(_ behavior: DefaultMacroBehavior) {
        defaultMacroBehavior = behavior
        if let encoded = try? JSONEncoder().encode(behavior) {
            defaults.set(encoded, forKey: Keys.defaultMacroBehavior)
        }
    }

    /// Snapshot of current settings — used by the launcher to apply at
    /// launch time without holding a reference to the store on a non-main
    /// actor.
    public func snapshot() -> Snapshot {
        Snapshot(framerateCap: framerateCap, fflags: fflags, activePreset: activePreset)
    }

    public struct Snapshot: Sendable, Equatable {
        public let framerateCap: Int?
        public let fflags: [String: AnyCodableValue]
        public let activePreset: FFlagPresetID?
    }

    private enum Keys {
        static let framerateCap = "rororo.launch.framerateCap"
        static let fflags = "rororo.launch.fflags"
        static let activePreset = "rororo.launch.activePreset"
        // Legacy — read once in `init` for the ADR 0011 migration, then removed.
        static let lowResourceMode = "rororo.launch.lowResourceMode"
        static let autoKeysLoopDelay = "rororo.autoKeys.loopDelay"
        static let autoKeysSafety = "rororo.autoKeys.safety"
        static let autoKeysStayAwakeMode = "rororo.autoKeys.stayAwakeMode"
        static let recorderHotkey = "rororo.autoKeys.recorderHotkey"
        static let defaultMacroBehavior = "rororo.autoKeys.defaultMacroBehavior"
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
