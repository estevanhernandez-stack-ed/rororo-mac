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

        let shareables = shareableSources
        if shareables.isEmpty {
            Text("No other account has a shared recording yet")
        } else {
            Menu("Use shared recording") {
                ForEach(shareables, id: \.id) { owner in
                    let label = pickerLabel(for: owner)
                    Button(account.autoKeysSourceAccountId == owner.id
                           ? "✓ \(label)"
                           : label) {
                        store.setAutoKeysSourceAccountId(
                            userId: account.userId,
                            sourceUserId: owner.id
                        )
                    }
                }
            }
        }

        if account.autoKeysSourceAccountId != nil {
            Button("Use my own recording") {
                store.setAutoKeysSourceAccountId(
                    userId: account.userId,
                    sourceUserId: nil
                )
            }
        }

        if account.autoKeys?.isEmpty == false {
            Divider()
            Button("Clear my recording", role: .destructive) {
                store.setAutoKeys(userId: account.userId, sequence: nil)
            }
        }
    }

    /// Every other account whose own recording is marked `isShared`.
    /// Legacy (non-stream) recordings can't be shared per ADR 0007 — the
    /// `isShared` flag only lives on stream variants. Self-excluded so
    /// an account doesn't appear in its own picker.
    private var shareableSources: [Account] {
        store.accounts.filter { other in
            guard other.userId != account.userId else { return false }
            guard let seq = other.autoKeys, !seq.isEmpty else { return false }
            return seq.isShared
        }
    }

    /// Render a picker label that includes the source's macro name
    /// when set ("Alice · Combat rotation"); falls back to bare display
    /// name when the recording is unnamed.
    private func pickerLabel(for owner: Account) -> String {
        if let macroName = owner.autoKeys?.name {
            return "\(owner.displayName) · \(macroName)"
        }
        return owner.displayName
    }

    // MARK: - Label

    /// Resolves the effective sequence the cycler will play (own vs
    /// shared vs orphan/broken). Drives the label + colors.
    private var resolution: AutoKeysSharingResolver.Resolution {
        AutoKeysSharingResolver.resolve(account: account, all: store.accounts)
    }

    private var label: String {
        switch resolution {
        case .ownEmpty:
            return "AUTO-KEYS"
        case let .ownRecording(seq):
            switch seq.variant {
            case .legacy:
                // LEGACY prefix flags pre-ADR-0007 sequences for the eye
                // scanner — re-recording opens the V2 sheet which writes
                // a stream variant on save.
                return "LEGACY · \(seq.steps.count) KEY\(seq.steps.count == 1 ? "" : "S")"
            case .stream:
                if let name = seq.name {
                    return name.uppercased()
                }
                let count = seq.actions.count
                return "\(count) ACT\(count == 1 ? "" : "S") · \(formatSeconds(seq.totalDuration))"
            }
        case let .sharedFrom(sourceId, seq):
            let ownerName = store.accounts.first(where: { $0.id == sourceId })?.displayName ?? "?"
            if let macroName = seq.name {
                return "\(ownerName.uppercased()) · \(macroName.uppercased())"
            }
            return "USING \(ownerName.uppercased())"
        case .orphaned, .sourceNotShared:
            return "SHARED · MISSING"
        }
    }

    private var helpText: String {
        switch resolution {
        case .ownEmpty:
            return "Auto-keys not configured. Click to record a sequence, or right-click to use another account's shared recording."
        case let .ownRecording(seq):
            switch seq.variant {
            case .legacy:
                return "Legacy \(seq.steps.count)-key recording, \(formatSeconds(seq.totalDuration)). Click to re-record with mouse + unlimited actions."
            case .stream:
                let sharedSuffix = seq.isShared ? " · shared with other accounts" : ""
                return "Recorded session: \(seq.actions.count) actions, \(formatSeconds(seq.totalDuration))\(sharedSuffix). Right-click to share or pick another account's recording."
            }
        case let .sharedFrom(sourceId, seq):
            let name = store.accounts.first(where: { $0.id == sourceId })?.displayName ?? "?"
            return "Using \(name)'s shared recording (\(seq.actions.count) actions, \(formatSeconds(seq.totalDuration))). Right-click to switch or revert to own."
        case let .orphaned(missingId):
            return "Referenced account \(missingId) is gone or has no recording. Right-click to clear or pick a different source."
        case let .sourceNotShared(sourceId):
            let name = store.accounts.first(where: { $0.id == sourceId })?.displayName ?? sourceId
            return "\(name) un-shared their recording. Right-click to clear or pick a different source."
        }
    }

    private var icon: String {
        switch resolution {
        case .ownEmpty:                    return "keyboard"
        case .ownRecording:                return "keyboard.fill"
        case .sharedFrom:                  return "person.2.fill"
        case .orphaned, .sourceNotShared:  return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch resolution {
        case .orphaned, .sourceNotShared:  return Theme.Color.stateWarn
        default:                           return Color.white.opacity(0.9)
        }
    }

    private var textColor: Color {
        switch resolution {
        case .orphaned, .sourceNotShared:  return Theme.Color.stateWarn
        default:                           return Color.white.opacity(0.85)
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            return String(format: "%.1fM", seconds / 60)
        }
        return String(format: "%.1fS", seconds)
    }
}
