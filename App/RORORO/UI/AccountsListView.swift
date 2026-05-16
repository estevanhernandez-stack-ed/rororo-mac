// AccountsListView.swift
// Account rows + "+ Add Account" button + a persistent default-game banner.
//
// Hybrid Launch As (per-row primary button):
//   - If FavoriteGameStore has a default favorite → launch into that.
//   - Otherwise → open the LaunchTargetPicker so the user picks (or
//     pastes a custom URL).
//
// Per-row ⋯ menu always opens LaunchTargetPicker for explicit overrides.

import SwiftUI

struct AccountsListView: View {
    @Binding var showAddAccount: Bool
    @Binding var showGames: Bool

    @ObservedObject private var launchSettings = LaunchSettingsStore.shared

    @State private var inFlightLaunchUserId: String?
    @State private var lastLaunchError: String?
    @State private var pendingPickerForAccount: Account?
    /// Slope B3' part 2 — inline relogin state. When a launch is gated
    /// by an expired cookie (either pre-click via `account.cookieStatus`
    /// or post-click via `APIError.cookieExpired`), we stash the launch
    /// args so the relogin success path can retry the user's original
    /// click without losing target.
    @State private var pendingReloginForAccount: Account?
    @State private var pendingReloginTarget: LaunchTarget?
    @State private var pendingReloginSavedServerId: UUID?
    /// Slope B1 — alert state for "Add to new group…". Held alongside
    /// the typed group-name binding so the alert's TextField is two-way.
    @State private var pendingNewGroupForAccount: Account?
    @State private var pendingNewGroupName: String = ""
    /// Slope B1 — pending Launch Group sheet state. The sheet asks for
    /// target + FPS-share decisions before fanning out N launches.
    @State private var pendingGroupLaunch: PendingGroupLaunch?
    /// Slope C wave 3b — pending auto-keys recorder. Tapping the row's
    /// AutoKeysRowBadge sets this; the .sheet(item:) below opens the
    /// recorder for that account.
    @State private var pendingAutoKeysRecorderForAccount: Account?

    /// Per ADR 0009 — first Launch As on any account triggers macOS
    /// TCC prompts under the re-signed per-account bundle ID. Show a
    /// one-time pre-flight alert so users understand what they'll see.
    /// Persists via UserDefaults; alert dismisses → flag set → never
    /// shows again on this machine. nil-coalescing default (false)
    /// covers users upgrading from v0.6.1 → v0.7.0.
    @AppStorage("rororo.hasShownTCCPreflightAlert") private var hasShownTCCPreflight: Bool = false
    @State private var pendingPostPreflightLaunch: (account: Account, target: LaunchTarget, savedServerId: UUID?)?

    private struct PendingGroupLaunch: Identifiable {
        let id = UUID()
        let groupName: String
        let accounts: [Account]
    }

    private let accountStore = AccountStore.shared
    private let favoriteStore = FavoriteGameStore.shared
    private let serverStore = PrivateServerStore.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                defaultGameBanner
                Group {
                    if accountStore.accounts.isEmpty {
                        emptyState
                    } else {
                        accountList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            addAccountButton
                .padding(Theme.Spacing.lg)
        }
        .alert("Launch failed", isPresented: Binding(
            get: { lastLaunchError != nil },
            set: { _ in lastLaunchError = nil }
        )) {
            Button("OK") { lastLaunchError = nil }
        } message: {
            Text(lastLaunchError ?? "")
        }
        .alert(
            "macOS will ask for permissions per account",
            isPresented: Binding(
                get: { pendingPostPreflightLaunch != nil },
                set: { newValue in if !newValue { pendingPostPreflightLaunch = nil } }
            ),
            presenting: pendingPostPreflightLaunch
        ) { pending in
            Button("Continue") {
                hasShownTCCPreflight = true
                let captured = pending
                pendingPostPreflightLaunch = nil
                launch(account: captured.account, target: captured.target, savedServerId: captured.savedServerId)
            }
            Button("Cancel", role: .cancel) {
                pendingPostPreflightLaunch = nil
            }
        } message: { _ in
            Text("RORORO launches each Roblox account under its own identity so accounts can't accidentally share a session. The first time you launch each account, macOS will ask for permissions Roblox normally requests (local network, microphone, etc.). You can decline any you don't use — Roblox plays normally without them. You'll see this message once.")
        }
        .sheet(item: $pendingPickerForAccount) { account in
            LaunchTargetPicker(
                account: account,
                onLaunch: { target, savedServerId in
                    pendingPickerForAccount = nil
                    launch(account: account, target: target, savedServerId: savedServerId)
                },
                onCancel: {
                    pendingPickerForAccount = nil
                }
            )
        }
        .sheet(item: $pendingReloginForAccount) { account in
            ReloginSheet(
                account: account,
                onComplete: { refreshed in
                    let target = pendingReloginTarget
                    let savedServerId = pendingReloginSavedServerId
                    pendingReloginForAccount = nil
                    pendingReloginTarget = nil
                    pendingReloginSavedServerId = nil
                    if let target {
                        launch(account: refreshed, target: target, savedServerId: savedServerId)
                    }
                },
                onCancel: {
                    pendingReloginForAccount = nil
                    pendingReloginTarget = nil
                    pendingReloginSavedServerId = nil
                }
            )
        }
        .alert(
            "New group",
            isPresented: Binding(
                get: { pendingNewGroupForAccount != nil },
                set: { newValue in
                    if !newValue {
                        pendingNewGroupForAccount = nil
                        pendingNewGroupName = ""
                    }
                }
            )
        ) {
            TextField("Group name", text: $pendingNewGroupName)
            Button("Create") {
                if let account = pendingNewGroupForAccount {
                    accountStore.setGroupName(userId: account.userId, name: pendingNewGroupName)
                }
                pendingNewGroupForAccount = nil
                pendingNewGroupName = ""
            }
            Button("Cancel", role: .cancel) {
                pendingNewGroupForAccount = nil
                pendingNewGroupName = ""
            }
        } message: {
            Text("Drop this account into a new group. Other accounts can join the same group from their menu.")
        }
        .sheet(item: $pendingAutoKeysRecorderForAccount) { account in
            // D-3.4 — V2 recorder replaces the legacy step-by-step sheet
            // as the chip's entry point. Legacy on-disk sequences still
            // run via the cycler's legacy variant path; the user must
            // re-record to upgrade to the action-stream format.
            AutoKeysRecorderV2Sheet(
                isPresented: Binding(
                    get: { pendingAutoKeysRecorderForAccount != nil },
                    set: { newValue in
                        if !newValue { pendingAutoKeysRecorderForAccount = nil }
                    }
                ),
                account: account
            )
        }
        .sheet(item: $pendingGroupLaunch) { pending in
            GroupLaunchSheet(
                groupName: pending.groupName,
                accounts: pending.accounts,
                favorites: favoriteStore.favorites,
                servers: serverStore.servers,
                onLaunch: { target, sharedCap in
                    let accounts = pending.accounts
                    pendingGroupLaunch = nil
                    launchGroup(accounts, target: target, sharedCap: sharedCap)
                },
                onCancel: { pendingGroupLaunch = nil }
            )
        }
    }

    // MARK: - Banner

    /// Always-visible banner. Resolves the current default across BOTH
    /// FavoriteGameStore and PrivateServerStore — the marked-default
    /// entry can be either a favorite game or a saved private server.
    private var defaultGameBanner: some View {
        let target = bannerTarget()
        return HStack(spacing: Theme.Spacing.md) {
            bannerIcon(target: target)
            VStack(alignment: .leading, spacing: 2) {
                Text("Default launch target")
                    .font(Theme.Font.monoMicro)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Color.fg3)
                if let target {
                    Text(target.name)
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not set — Launch As will open a picker.")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.stateWarn)
                }
            }
            Spacer()
            Button(target == nil ? "Set up" : "Manage") {
                showGames = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Color.bgSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Color.bgRaised)
                .frame(height: 1)
        }
    }

    private struct BannerTarget {
        let name: String
        let thumbnailURL: URL?
        let kind: Kind
        enum Kind { case favorite, privateServer }
    }

    private func bannerTarget() -> BannerTarget? {
        if let fav = favoriteStore.defaultGame() {
            return BannerTarget(name: fav.name, thumbnailURL: fav.thumbnailURL, kind: .favorite)
        }
        if let server = serverStore.defaultServer() {
            return BannerTarget(name: server.name, thumbnailURL: server.thumbnailURL, kind: .privateServer)
        }
        return nil
    }

    @ViewBuilder
    private func bannerIcon(target: BannerTarget?) -> some View {
        if let url = target?.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: bannerIconPlaceholder(kind: target?.kind)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            bannerIconPlaceholder(kind: target?.kind)
                .frame(width: 28, height: 28)
        }
    }

    private func bannerIconPlaceholder(kind: BannerTarget.Kind?) -> some View {
        Image(systemName: kind == .privateServer ? "lock.shield" : "gamecontroller")
            .foregroundStyle(Theme.Color.brandCyan)
            .imageScale(.large)
    }

    // MARK: - List + empty

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Color.fg3)
            Text("No saved accounts")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)
            Text("Add a Roblox account to start launching with one click.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                showAddAccount = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.Color.productTeal)
        }
        .padding(Theme.Spacing.xl)
    }

    private var accountList: some View {
        let defaultName = RobloxLauncher.currentDefaultDisplayName()
        let groups = groupedAccounts()
        let existingGroups = accountStore.uniqueGroupNames()
        return List {
            ForEach(groups) { group in
                if let groupName = group.name {
                    Section {
                        ForEach(group.accounts) { account in
                            row(for: account, defaultName: defaultName, existingGroups: existingGroups)
                        }
                    } header: {
                        groupHeader(name: groupName, accounts: group.accounts)
                    }
                } else {
                    // Ungrouped accounts render without a header so the
                    // existing flat-list look survives until a user
                    // opts in to grouping.
                    ForEach(group.accounts) { account in
                        row(for: account, defaultName: defaultName, existingGroups: existingGroups)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Section header for a named account group. Shows the group name
    /// + a "Launch group" button that opens the GroupLaunchSheet to
    /// collect target + FPS-share choices before fanning launches out
    /// through MultiInstanceCoordinator's serial queue.
    private func groupHeader(name: String, accounts: [Account]) -> some View {
        HStack {
            Text(name.uppercased())
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)
                .tracking(1.4)
            Spacer()
            Button("Launch group") {
                pendingGroupLaunch = PendingGroupLaunch(
                    groupName: name,
                    accounts: accounts
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.Color.productTeal)
            .disabled(accounts.isEmpty)
        }
    }

    @ViewBuilder
    private func row(for account: Account, defaultName: String?, existingGroups: [String]) -> some View {
        AccountRow(
            account: account,
            isLaunching: inFlightLaunchUserId == account.userId,
            defaultDisplayName: defaultName,
            favorites: favoriteStore.favorites,
            servers: serverStore.servers,
            existingGroups: existingGroups,
            globalFramerateCap: launchSettings.framerateCap,
            onLaunchPrimary: { launchPrimary(account: account) },
            onPickFavorite: { game in
                launch(account: account, target: .place(placeId: game.placeId), savedServerId: nil)
            },
            onPickServer: { server in
                launch(
                    account: account,
                    target: .privateServer(
                        placeId: server.placeId,
                        code: server.code,
                        kind: server.codeKind
                    ),
                    savedServerId: server.id
                )
            },
            onLaunchCustom: { pendingPickerForAccount = account },
            onSetFramerateCap: { cap in
                accountStore.setFramerateCapOverride(userId: account.userId, cap: cap)
            },
            onSetGroup: { name in
                accountStore.setGroupName(userId: account.userId, name: name)
            },
            onAddNewGroup: {
                pendingNewGroupForAccount = account
                pendingNewGroupName = ""
            },
            onRemove: { remove(account: account) },
            onOpenAutoKeysRecorder: {
                pendingAutoKeysRecorderForAccount = account
            }
        )
    }

    private struct AccountGroup: Identifiable {
        let id: String           // groupName, or "__ungrouped__" sentinel
        let name: String?        // nil means the ungrouped bucket
        let accounts: [Account]
    }

    /// Cluster the saved accounts by `groupName`. Ungrouped sit in
    /// their own bucket at the top of the list (no header). Named
    /// groups follow alphabetically. Order within a group preserves
    /// AccountStore's insertion order so power users see a stable
    /// list across re-renders.
    private func groupedAccounts() -> [AccountGroup] {
        let all = accountStore.accounts
        let buckets = Dictionary(grouping: all, by: { $0.groupName })
        var result: [AccountGroup] = []
        if let ungrouped = buckets[nil], !ungrouped.isEmpty {
            result.append(AccountGroup(id: "__ungrouped__", name: nil, accounts: ungrouped))
        }
        let namedKeys = buckets.keys.compactMap { $0 }.sorted()
        for key in namedKeys {
            result.append(AccountGroup(id: key, name: key, accounts: buckets[key] ?? []))
        }
        return result
    }

    /// Fan out a launch for every account in `accounts`, using the
    /// group-launch modifiers chosen in `GroupLaunchSheet`. Each launch
    /// goes through the same launch(account:target:savedServerId:)
    /// path, which yields to MultiInstanceCoordinator's serial queue.
    ///
    /// `target` nil → each account uses `.defaultGame` (the global
    /// favorite/server default). Concrete value → every account in the
    /// group launches into the same place.
    ///
    /// `sharedCap` nil → each account uses its own framerateCapOverride
    /// (or the global cap when no override). Concrete value → we hand
    /// each launch a transient Account snapshot with that cap forced
    /// in, so the launch flow's existing override-or-global precedence
    /// resolves to the shared value without persisting it on disk.
    private func launchGroup(_ accounts: [Account], target: LaunchTarget?, sharedCap: Int?) {
        let effectiveTarget = target ?? .defaultGame
        let savedServerId: UUID? = {
            if case .privateServer = effectiveTarget,
               let server = serverStore.servers.first(where: { server in
                   target.flatMap { matchesServer($0, server) } ?? false
               }) {
                return server.id
            }
            return nil
        }()
        for account in accounts {
            var effective = account
            if let sharedCap {
                effective.framerateCapOverride = sharedCap
            }
            launch(account: effective, target: effectiveTarget, savedServerId: savedServerId)
        }
    }

    /// Match a chosen LaunchTarget back to the SavedPrivateServer that
    /// produced it, so the savedServerId tracking touch fires after
    /// the group launch lands.
    private func matchesServer(_ target: LaunchTarget, _ server: SavedPrivateServer) -> Bool {
        if case .privateServer(let placeId, let code, let kind) = target {
            return server.placeId == placeId && server.code == code && server.codeKind == kind
        }
        return false
    }

    private var addAccountButton: some View {
        Button {
            showAddAccount = true
        } label: {
            Label("Add Account", systemImage: "plus")
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(Theme.Color.productTeal)
    }

    // MARK: - Launch flow

    /// Hybrid behavior: if a default favorite is set, launch into it
    /// immediately; otherwise open the picker.
    private func launchPrimary(account: Account) {
        if FavoriteGameStore.shared.defaultGame() != nil {
            launch(account: account, target: .defaultGame, savedServerId: nil)
        } else {
            pendingPickerForAccount = account
        }
    }

    private func launch(account: Account, target: LaunchTarget, savedServerId: UUID?) {
        // ADR 0009 pre-flight — first Launch As on this machine (any
        // account) triggers TCC prompts under the re-signed per-account
        // bundle ID. Show a one-time alert so the prompts aren't a
        // surprise. The alert's Continue action recursively invokes
        // launch() with the original args after setting the flag.
        if !hasShownTCCPreflight {
            pendingPostPreflightLaunch = (account, target, savedServerId)
            return
        }

        // Slope B3' part 2 — proactive relogin gate. If we already
        // know the cookie is expired (boot probe or prior launch
        // failure), skip the doomed launch attempt and pop the
        // relogin sheet directly. The sheet's onComplete recursively
        // calls back into launch() with the refreshed account and
        // the original target.
        if account.cookieStatus == .expired {
            pendingReloginTarget = target
            pendingReloginSavedServerId = savedServerId
            pendingReloginForAccount = account
            return
        }
        inFlightLaunchUserId = account.userId
        Task { @MainActor in
            defer { inFlightLaunchUserId = nil }
            do {
                try await RobloxLauncher.shared.launch(account: account, target: target)
                if let savedServerId {
                    PrivateServerStore.shared.touchLastLaunched(id: savedServerId)
                }
            } catch let error as RobloxApi.APIError {
                // Mark the cookie expired in AccountStore so the row
                // UI surfaces the badge BEFORE the next click attempt
                // (Slope B3'). RobloxLauncher's getAuthTicket converts
                // a 401 into APIError.cookieExpired; we trust that
                // signal here. Then pop the relogin sheet inline rather
                // than the generic alert — saves the user a click.
                if case .cookieExpired = error {
                    accountStore.setCookieStatus(userId: account.userId, status: .expired)
                    pendingReloginTarget = target
                    pendingReloginSavedServerId = savedServerId
                    pendingReloginForAccount = account
                    return
                }
                lastLaunchError = describe(apiError: error)
            } catch let error as RobloxLauncher.LauncherError {
                lastLaunchError = describe(launcherError: error)
            } catch {
                lastLaunchError = error.localizedDescription
            }
        }
    }

    private func remove(account: Account) {
        do {
            try accountStore.remove(userId: account.userId)
        } catch {
            lastLaunchError = "Failed to remove account: \(error.localizedDescription)"
        }
    }

    private func describe(apiError: RobloxApi.APIError) -> String {
        switch apiError {
        case .cookieExpired:
            return "This account's login expired. Remove and re-add it."
        case .transient(let status):
            return "Roblox is having trouble (HTTP \(status)). Try again in a moment."
        case .unexpected(_, let message):
            return message
        }
    }

    private func describe(launcherError: RobloxLauncher.LauncherError) -> String {
        switch launcherError {
        case .unresolvedDefaultGame:
            return "No default game set. Click Games in the toolbar to add one."
        case .cookieMissing(let userId):
            return "No cookie stored for account \(userId). Remove and re-add the account."
        case .invalidLaunchURI:
            return "Could not build the launch URI. Please report this."
        case .invalidTarget(let reason):
            return "Invalid target: \(reason)"
        case .emptyTicket, .emptyPlaceURL, .emptyBrowserTrackerId:
            return "Internal error building the launch URI. Please report this."
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let isLaunching: Bool
    let defaultDisplayName: String?
    let favorites: [FavoriteGame]
    let servers: [SavedPrivateServer]
    let existingGroups: [String]
    let globalFramerateCap: Int?
    let onLaunchPrimary: () -> Void
    let onPickFavorite: (FavoriteGame) -> Void
    let onPickServer: (SavedPrivateServer) -> Void
    let onLaunchCustom: () -> Void
    let onSetFramerateCap: (Int?) -> Void
    let onSetGroup: (String?) -> Void
    let onAddNewGroup: () -> Void
    let onRemove: () -> Void
    /// Slope C wave 3b — open the per-account auto-keys recorder.
    let onOpenAutoKeysRecorder: () -> Void

    /// Frame-rate cap options surfaced in the per-account menu. nil =
    /// "Use global" (fall back to LaunchSettingsStore.shared.framerateCap).
    private static let framerateCapOptions: [Int] = [20, 30, 60, 144]

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.fg1)
                Text("@\(account.username)")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
                if account.cookieStatus == .expired {
                    // Slope B3′ — surface cookie expiry per-row so
                    // users see the rot before they click Launch As
                    // and hit a generic alert. Boot-time probe in
                    // App.onAppear refreshes this; launch-time
                    // .cookieExpired catch in AccountsListView.launch
                    // also marks expired live.
                    Text("Login expired — needs re-login")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.stateDanger)
                } else if let last = account.lastLaunchedAt {
                    Text("Last launched \(last.formatted(.relative(presentation: .named)))")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.fg3)
                }
            }
            Spacer()
            // Auto-keys badge (Slope C wave 3b). Sits adjacent to the
            // launch button — a separate affordance, not part of the
            // launch flow. Tap opens the per-account recorder.
            AutoKeysRowBadge(account: account, onTap: onOpenAutoKeysRecorder)
            if isLaunching {
                ProgressView().controlSize(.small)
            } else {
                splitLaunchButton
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// Visual: one continuous brand gradient (cyan → teal) containing
    /// the primary label and a chevron dropdown. No divider — the chevron
    /// sits on the same surface, distinguished by its glyph + smaller pad.
    /// Hairline outer border keeps it readable against the dark row surface.
    ///
    /// Picking from the dropdown launches the chosen target for THIS click
    /// only. The default is sticky — it changes only via the explicit
    /// "Set as default" button in the Games tab.
    private var splitLaunchButton: some View {
        HStack(spacing: 0) {
            Button(action: onLaunchPrimary) {
                Text(primaryLabel)
                    .font(Theme.Font.bodySmall)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Per-account framerate override badge (see
            // docs/superpowers/specs/2026-05-14-framerate-override-visibility-design.md).
            // FramerateOverrideDivergence picks the styling: warn pill
            // when the override diverges from the global (the trap), or
            // today's subtle in-button styling when the override matches
            // the global or no global is set.
            if let cap = account.framerateCapOverride {
                overrideBadge(cap: cap, global: globalFramerateCap)
            }

            Menu {
                Button("Launch into default", action: onLaunchPrimary)
                    .disabled(defaultDisplayName == nil)
                if !favorites.isEmpty {
                    Section("Favorite games") {
                        ForEach(favorites) { game in
                            Button(game.isDefault ? "\(game.name) — current default" : game.name) {
                                onPickFavorite(game)
                            }
                        }
                    }
                }
                if !servers.isEmpty {
                    Section("Saved private servers") {
                        ForEach(servers) { server in
                            Button(server.isDefault ? "\(server.name) — current default" : server.name) {
                                onPickServer(server)
                            }
                        }
                    }
                }
                if !favorites.isEmpty || !servers.isEmpty {
                    Divider()
                }
                Button("Pick game / server…", action: onLaunchCustom)
                Divider()
                Menu("Group") {
                    Button(account.groupName == nil
                           ? "✓ Ungrouped"
                           : "Ungrouped") {
                        onSetGroup(nil)
                    }
                    if !existingGroups.isEmpty {
                        Divider()
                        ForEach(existingGroups, id: \.self) { name in
                            Button(account.groupName == name
                                   ? "✓ \(name)"
                                   : name) {
                                onSetGroup(name)
                            }
                        }
                    }
                    Divider()
                    Button("Add to new group…", action: onAddNewGroup)
                }
                Section("Frame rate cap (this account)") {
                    Button(account.framerateCapOverride == nil
                           ? "✓ Use global"
                           : "Use global") {
                        onSetFramerateCap(nil)
                    }
                    ForEach(Self.framerateCapOptions, id: \.self) { value in
                        Button(account.framerateCapOverride == value
                               ? "✓ \(value) fps"
                               : "\(value) fps") {
                            onSetFramerateCap(value)
                        }
                    }
                }
                Divider()
                Button("Remove account", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.trailing, 10)
                    .padding(.leading, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
        }
        .background(
            LinearGradient(
                colors: [Theme.Color.brandCyan, Theme.Color.productTeal],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        )
    }

    /// Per-account framerate override badge. Two visual states driven by
    /// FramerateOverrideDivergence:
    ///
    /// - **Warn pill** (amber background, dark text, ⚠ + cap value) when
    ///   the override diverges from the global. This is the trap to
    ///   surface — the user changed the global and the override silently
    ///   wins on launch.
    /// - **Subtle in-button text** (today's styling, preserved verbatim)
    ///   when the override matches the global or no global is set. No
    ///   nag when there is no real surprise.
    @ViewBuilder
    private func overrideBadge(cap: Int, global: Int?) -> some View {
        if let global, FramerateOverrideDivergence.diverges(override: cap, global: global) {
            // Warn pill — global is unwrapped here per the divergence rule.
            HStack(spacing: 4) {
                Text("⚠")
                Text("\(cap)")
            }
            .font(Theme.Font.monoMicro)
            .foregroundStyle(Theme.Color.bgPage)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.Color.stateWarn, in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .help("Per-account override: \(cap)fps. Global is \(global)fps.")
            .accessibilityLabel(
                "Per-account framerate cap override: \(cap) frames per second; differs from global setting"
            )
        } else {
            // Match or no global — keep today's subtle in-button styling.
            Text("\(cap)FPS")
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Color.white.opacity(0.85))
                .tracking(0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .accessibilityLabel("Per-account framerate cap: \(cap) frames per second")
        }
    }

    /// Primary button text — short. Long target names blew up the row
    /// width at v0.2 manual smoke; the dropdown items already show the
    /// full target name, so this just communicates "we're targeting the
    /// default" without naming it.
    private var primaryLabel: String {
        defaultDisplayName != nil ? "Launch As default" : "Launch As"
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = account.avatarThumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholderAvatar
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            placeholderAvatar
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(Theme.Color.bgRaised)
            .frame(width: 44, height: 44)
            .overlay(
                Text(String(account.displayName.prefix(1)))
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg2)
            )
    }
}
