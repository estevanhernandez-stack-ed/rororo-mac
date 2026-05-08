// ReloginSheet.swift
// Modal sheet for re-authenticating an existing Account whose
// `.ROBLOSECURITY` cookie has expired. Hosts the same `CookieCapture`
// WKWebView used by AddAccountSheet, but validates that the captured
// userId matches the existing account before persisting — so users
// who accidentally log into a different Roblox account don't silently
// overwrite the original record.
//
// Lifecycle (Slope B3' part 2):
//   1. AccountsListView.launch sees account.cookieStatus == .expired
//      OR catches APIError.cookieExpired post-launch.
//   2. Sets pendingReloginForAccount → triggers .sheet(item:).
//   3. User logs back in via WKWebView; CookieCapture extracts the
//      fresh `.ROBLOSECURITY` and calls onCaptured.
//   4. We validate captured.userId == account.userId. Mismatch surfaces
//      an inline error and stays in the sheet so the user can retry.
//   5. Match → AccountStore.add upserts the refreshed Account
//      (preserving framerateCapOverride, avatar, lastLaunchedAt) +
//      Keychain cookie. cookieStatus flips to .healthy, cookieCheckedAt
//      to now.
//   6. onComplete fires with the refreshed Account; AccountsListView
//      retries the queued launch with the fresh credentials.

import SwiftUI

struct ReloginSheet: View {
    let account: Account
    let onComplete: (Account) -> Void
    let onCancel: () -> Void

    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Re-login \(account.displayName)")
                        .font(Theme.Font.heading2)
                        .foregroundStyle(Theme.Color.fg1)
                    Text("Sign back in as @\(account.username) to refresh the saved cookie.")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg3)
                }
                Spacer()
                Button("Cancel") { onCancel() }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Color.bgSurface)

            CookieCapture(
                onCaptured: { captured in handleCapture(captured) },
                onCancel: { /* sheet's Cancel button covers user-side cancel */ }
            )
            .frame(minWidth: 480, minHeight: 640)

            if let error {
                Text(error)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.stateDanger)
                    .padding(Theme.Spacing.sm)
            }
        }
        .background(Theme.Color.bgPage)
        .frame(width: 480, height: 720)
    }

    private func handleCapture(_ captured: CookieCapture.CapturedAccount) {
        // Validate identity. If the user signed into a DIFFERENT Roblox
        // account, refuse to overwrite — that would silently lose the
        // original account's cookie. Inline error keeps the sheet open
        // so the user can log out + retry as the right account.
        guard captured.userId == account.userId else {
            error = "Signed in as @\(captured.username), but this row is for @\(account.username). Sign out from the form and try again."
            return
        }

        // Build a refreshed Account preserving non-cookie state. Username
        // / displayName come from the fresh capture (Roblox may have
        // changed them since last login).
        let refreshed = Account(
            userId: account.userId,
            username: captured.username,
            displayName: captured.displayName,
            avatarThumbnailURL: account.avatarThumbnailURL,
            lastLaunchedAt: account.lastLaunchedAt,
            framerateCapOverride: account.framerateCapOverride,
            cookieStatus: .healthy,
            cookieCheckedAt: Date()
        )

        do {
            // AccountStore.add upserts: replaces the existing record for
            // this userId in the JSON + writes the new cookie to Keychain.
            try AccountStore.shared.add(account: refreshed, cookie: captured.cookie)
            onComplete(refreshed)
        } catch {
            self.error = "Failed to save refreshed cookie: \(error.localizedDescription)"
        }
    }
}
