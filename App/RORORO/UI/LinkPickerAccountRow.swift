// LinkPickerAccountRow.swift
// UI — one clickable row in the inbound-link account picker. Pure
// presentation: takes the account, an external running-state value,
// and a tap callback. Visual treatment follows the existing Theme.
//
// Not a reuse of AccountsListView's row — that row carries split-launch
// button + chevron + framerate badge + macro state, all of which are
// the wrong affordance here. The picker is "click row → launch", end
// of story.

import SwiftUI

public struct LinkPickerAccountRow: View {

    public enum RunningState {
        case idle
        case running
        case active
    }

    public let account: Account
    public let runningState: RunningState
    public let onTap: () -> Void

    public init(account: Account, runningState: RunningState, onTap: @escaping () -> Void) {
        self.account = account
        self.runningState = runningState
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.body)
                        .foregroundStyle(Theme.Color.fg1)
                    Text("@\(account.username)")
                        .font(.caption)
                        .foregroundStyle(Theme.Color.fg2)
                }
                Spacer()
                statePill
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.Color.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Indicator-dot color tracks `runningState` so the dot and the
    /// pill reinforce the same signal (neutral / running / active)
    /// instead of the dot reading as "active" on every row.
    private var indicatorColor: Color {
        switch runningState {
        case .idle:    return Theme.Color.fg3        // slate — clearly inactive
        case .running: return Theme.Color.stateWarn  // amber — alive but not focused
        case .active:  return Theme.Color.brandCyan  // cyan — matches the pill
        }
    }

    @ViewBuilder
    private var statePill: some View {
        switch runningState {
        case .idle:
            EmptyView()
        case .running:
            Text("running")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.Color.fg2)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                // Inset surface — one step darker than the row's bgRaised
                // so the capsule shape actually reads against the card.
                .background(Theme.Color.bgSurface)
                .clipShape(Capsule())
        case .active:
            Text("active")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.Color.brandCyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.Color.brandCyan.opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

#Preview("LinkPickerAccountRow — three states") {
    VStack(spacing: 8) {
        LinkPickerAccountRow(
            account: Account(userId: "1", username: "alt1", displayName: "AltAcct1"),
            runningState: .idle,
            onTap: {}
        )
        LinkPickerAccountRow(
            account: Account(userId: "2", username: "alt2", displayName: "AltAcct2"),
            runningState: .running,
            onTap: {}
        )
        LinkPickerAccountRow(
            account: Account(userId: "3", username: "alt3", displayName: "AltAcct3"),
            runningState: .active,
            onTap: {}
        )
    }
    .padding(16)
    .frame(width: 360)
}
