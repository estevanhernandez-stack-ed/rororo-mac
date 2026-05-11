// AutoKeysRowBadge.swift
// Per-account row entry into the recorder sheet. Tap → V2 recorder
// (post-D-3.4). Right-click context menu → sharing controls
// (D-3.5 ADR 0007 Decision 7): pick another account's shared
// recording, clear the sharing reference, or clear the local
// recording entirely.
//
// The label reflects what the cycler will actually play for this
// account at runtime, surfaced through the same `AutoKeysSharingResolver`
// the cycler reads from. Five user-visible states:
//   - Not configured                 → "AUTO-KEYS"
//   - Own legacy recording           → "N KEYS · Ts"
//   - Own stream recording           → "N ACTS · Ts" (+ "shared" in help)
//   - Using shared (source healthy)  → "USING X" with shared icon
//   - Using shared (broken)          → "USING X · MISSING" warn-colored

import SwiftUI

struct AutoKeysRowBadge: View {

    let account: Account
    let onTap: () -> Void

    private let store = AccountStore.shared
    private let settings = LaunchSettingsStore.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(textColor)
                    .tracking(0.4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Record / re-record…", action: onTap)

        Divider()

        let shareables = shareableMacros
        if shareables.isEmpty {
            Text("No other shared macros yet")
        } else {
            Menu("Use macro") {
                ForEach(shareables, id: \.id) { macro in
                    let label = pickerLabel(for: macro)
                    Button(account.activeMacroId == macro.id
                           ? "✓ \(label)"
                           : label) {
                        store.setActiveMacroId(
                            userId: account.userId,
                            macroId: macro.id
                        )
                    }
                }
            }
        }

        // "Use my own" — only meaningful when this account has at least
        // one macro in the library (D-4.3 — own macros are first-class).
        let ownMacros = MacroStore.shared.macros(ownedBy: account.userId)
        if !ownMacros.isEmpty {
            Menu("Use my recording") {
                ForEach(ownMacros, id: \.id) { macro in
                    Button(account.activeMacroId == macro.id
                           ? "✓ \(macro.name)"
                           : macro.name) {
                        store.setActiveMacroId(
                            userId: account.userId,
                            macroId: macro.id
                        )
                    }
                }
            }
        }

        if account.activeMacroId != nil {
            Button("Clear active macro") {
                store.setActiveMacroId(userId: account.userId, macroId: nil)
            }
        }
    }

    /// Shareable macros from the library, excluding any owned by this
    /// account — drives the right-click picker submenu.
    private var shareableMacros: [Macro] {
        MacroStore.shared.sharedMacros(excludingOwner: account.userId)
    }

    /// Picker label including owner attribution when the macro has one.
    private func pickerLabel(for macro: Macro) -> String {
        if let ownerId = macro.ownerUserId,
           let owner = store.accounts.first(where: { $0.id == ownerId }) {
            return "\(owner.displayName) · \(macro.name)"
        }
        return macro.name
    }

    // MARK: - Label

    /// Resolves what the cycler will play for this account. Drives the
    /// label + colors. D-4.3 — library-aware.
    private var resolution: AutoKeysSharingResolver.Resolution {
        AutoKeysSharingResolver.resolve(
            account: account,
            macros: MacroStore.shared.macros,
            globalDefault: settings.defaultMacroBehavior
        )
    }

    private var label: String {
        switch resolution {
        case .none:
            return "AUTO-KEYS"
        case let .playing(macro):
            if let ownerId = macro.ownerUserId, ownerId != account.userId {
                let owner = store.accounts.first(where: { $0.id == ownerId })?.displayName ?? "?"
                return "\(owner.uppercased()) · \(macro.name.uppercased())"
            }
            // Own macro — show macro name only.
            if macro.isLegacy {
                return "LEGACY · \(macro.name.uppercased())"
            }
            return macro.name.uppercased()
        case let .usingGlobalDefault(reason, _):
            switch reason {
            case .stayAlive:
                return "DEFAULT · STAY ALIVE"
            case let .usingMacro(macro):
                if let ownerId = macro.ownerUserId,
                   let owner = store.accounts.first(where: { $0.id == ownerId }) {
                    return "DEFAULT · \(owner.displayName.uppercased())/\(macro.name.uppercased())"
                }
                return "DEFAULT · \(macro.name.uppercased())"
            }
        case .orphaned:
            return "MACRO · MISSING"
        }
    }

    private var helpText: String {
        switch resolution {
        case .none:
            return "No macro selected. Click to record one, or right-click to pick from the library."
        case let .playing(macro):
            let ownerName: String? = {
                guard let id = macro.ownerUserId else { return nil }
                return store.accounts.first(where: { $0.id == id })?.displayName
            }()
            let actionCount: Int
            switch macro.variant {
            case let .legacy(steps): actionCount = steps.count
            case let .stream(actions): actionCount = actions.count
            }
            let owner = ownerName ?? "?"
            let unit = macro.isLegacy ? "step" : "action"
            let plural = actionCount == 1 ? "" : "s"
            if macro.ownerUserId == account.userId {
                let sharedSuffix = macro.isShared ? " · shared with other accounts" : ""
                return "Macro: \(macro.name) — \(actionCount) \(unit)\(plural)\(sharedSuffix). Right-click to share / pick another / clear."
            }
            return "Using \(owner)'s macro: \(macro.name) (\(actionCount) \(unit)\(plural)). Right-click to switch."
        case let .usingGlobalDefault(reason, _):
            switch reason {
            case .stayAlive:
                return "Falling back to the global default — synthesized spacebar keeps this account alive. Record a macro for this account to override, or change the default in the cycler toolbar."
            case let .usingMacro(macro):
                let ownerName = macro.ownerUserId.flatMap { id in
                    store.accounts.first(where: { $0.id == id })?.displayName
                } ?? "?"
                return "Falling back to the global default — playing \(macro.name) (from \(ownerName)). Right-click to pick your own or change the default."
            }
        case let .orphaned(macroId):
            return "Active macro \(macroId) is missing from the library. Right-click to clear or pick a different one."
        }
    }

    private var icon: String {
        switch resolution {
        case .none:                return "keyboard"
        case let .playing(macro):
            if let ownerId = macro.ownerUserId, ownerId != account.userId {
                return "person.2.fill"
            }
            return "keyboard.fill"
        case .usingGlobalDefault:  return "checkmark.shield"
        case .orphaned:            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch resolution {
        case .orphaned:            return Theme.Color.stateWarn
        case .usingGlobalDefault:  return Theme.Color.fg2.opacity(0.95)
        default:                   return Color.white.opacity(0.9)
        }
    }

    private var textColor: Color {
        switch resolution {
        case .orphaned:            return Theme.Color.stateWarn
        case .usingGlobalDefault:  return Theme.Color.fg2
        default:                   return Color.white.opacity(0.85)
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            return String(format: "%.1fM", seconds / 60)
        }
        return String(format: "%.1fS", seconds)
    }
}
