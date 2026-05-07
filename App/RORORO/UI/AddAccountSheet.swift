// AddAccountSheet.swift
// Modal sheet that hosts the WKWebView login (CookieCapture). On
// successful capture, persists to AccountStore and dismisses.

import SwiftUI

struct AddAccountSheet: View {
    @Binding var isPresented: Bool
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Roblox Account")
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Button("Cancel") { isPresented = false }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Color.bgSurface)

            CookieCapture(
                onCaptured: { captured in handleCapture(captured) },
                onCancel: { /* user closed — no-op */ }
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
        let account = Account(
            userId: captured.userId,
            username: captured.username,
            displayName: captured.displayName,
            avatarThumbnailURL: nil,
            lastLaunchedAt: nil
        )
        do {
            try AccountStore.shared.add(account: account, cookie: captured.cookie)
            // Best-effort avatar fetch in the background. Account is already
            // saved; a missing avatar is cosmetic.
            Task.detached {
                if let userId = Int64(captured.userId),
                   let avatar = try? await RobloxApi.getAvatarHeadshotURL(userId: userId) {
                    await MainActor.run {
                        AccountStore.shared.updateProfile(
                            userId: captured.userId,
                            avatarThumbnailURL: avatar
                        )
                    }
                }
            }
            isPresented = false
        } catch {
            self.error = "Failed to save account: \(error.localizedDescription)"
        }
    }
}
