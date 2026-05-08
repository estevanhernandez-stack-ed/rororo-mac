// GroupLaunchSheet.swift
// Modal modifiers for the per-group "Launch group" command (Slope B1).
//
// Asks two questions before fanning out N launches through the
// MultiInstanceCoordinator queue:
//
//   1. Game / server target — same target for everyone in the group,
//      or each account uses whatever the global default already is.
//      "Same target" lets a user spin up 5 alts into one specific
//      game without setting a global default first.
//   2. FPS cap policy — shared across the group, or each account's
//      own override (which itself falls back to the global cap when
//      no per-account override is set). "Shared" is the multi-instance
//      throttle case: every alt at 20 fps so the GPU survives.
//
// On Launch, returns a (target, sharedCap) tuple to AccountsListView.
//   - target: nil means ".defaultGame" per account (global default).
//   - sharedCap: nil means "use each account's own override".
// AccountsListView builds an effective Account snapshot per launch and
// fans them out through the existing single-account launch path.

import SwiftUI

struct GroupLaunchSheet: View {
    let groupName: String
    let accounts: [Account]
    let favorites: [FavoriteGame]
    let servers: [SavedPrivateServer]
    let onLaunch: (LaunchTarget?, Int?) -> Void
    let onCancel: () -> Void

    enum TargetMode: Hashable {
        case useDefaults
        case sameFavorite
        case sameServer
    }

    enum FpsMode: Hashable {
        case perAccount
        case shared
    }

    @State private var targetMode: TargetMode = .useDefaults
    @State private var pickedFavoritePlaceId: Int64?
    @State private var pickedServerId: UUID?

    @State private var fpsMode: FpsMode = .perAccount
    @State private var sharedFps: Int = 20

    private static let fpsOptions: [Int] = [20, 30, 60, 144]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header

            section("Game / server") {
                Picker("Target mode", selection: $targetMode) {
                    Text("Each account's default").tag(TargetMode.useDefaults)
                    if !favorites.isEmpty {
                        Text("Same favorite for everyone").tag(TargetMode.sameFavorite)
                    }
                    if !servers.isEmpty {
                        Text("Same private server for everyone").tag(TargetMode.sameServer)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if targetMode == .sameFavorite, !favorites.isEmpty {
                    Picker("Favorite game", selection: $pickedFavoritePlaceId) {
                        Text("Choose a favorite…").tag(Int64?.none)
                        ForEach(favorites) { game in
                            Text(game.name).tag(Int64?.some(game.placeId))
                        }
                    }
                    .pickerStyle(.menu)
                }
                if targetMode == .sameServer, !servers.isEmpty {
                    Picker("Private server", selection: $pickedServerId) {
                        Text("Choose a server…").tag(UUID?.none)
                        ForEach(servers) { server in
                            Text(server.name).tag(UUID?.some(server.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            section("FPS cap") {
                Picker("FPS mode", selection: $fpsMode) {
                    Text("Each account's own setting").tag(FpsMode.perAccount)
                    Text("Shared across the group").tag(FpsMode.shared)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if fpsMode == .shared {
                    Picker("Shared cap", selection: $sharedFps) {
                        ForEach(Self.fpsOptions, id: \.self) { value in
                            Text("\(value) fps").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Text(fpsMode == .shared
                     ? "Roblox-wide cap: every Roblox instance is throttled at this rate while these launches are in flight. Per-account overrides are ignored for this group launch."
                     : "Each account uses its own framerate override (or the global cap if none).")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }

            Spacer()

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button(launchButtonLabel) {
                    fire()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.productTeal)
                .disabled(!canLaunch)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(minWidth: 460, minHeight: 460)
        .background(Theme.Color.bgPage)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launch group")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)
            Text("\(groupName) — \(accounts.count) accounts")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg3)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)
                .tracking(1.4)
            content()
        }
    }

    private var launchButtonLabel: String {
        "Launch \(accounts.count)"
    }

    /// Disable the launch button if the user picked "same target" but
    /// hasn't selected an actual game / server yet.
    private var canLaunch: Bool {
        switch targetMode {
        case .useDefaults: return true
        case .sameFavorite: return pickedFavoritePlaceId != nil
        case .sameServer: return pickedServerId != nil
        }
    }

    private func fire() {
        let target: LaunchTarget? = {
            switch targetMode {
            case .useDefaults:
                return nil
            case .sameFavorite:
                guard let placeId = pickedFavoritePlaceId else { return nil }
                return .place(placeId: placeId)
            case .sameServer:
                guard let id = pickedServerId,
                      let server = servers.first(where: { $0.id == id }) else {
                    return nil
                }
                return .privateServer(
                    placeId: server.placeId,
                    code: server.code,
                    kind: server.codeKind
                )
            }
        }()
        let cap: Int? = (fpsMode == .shared) ? sharedFps : nil
        onLaunch(target, cap)
    }
}
