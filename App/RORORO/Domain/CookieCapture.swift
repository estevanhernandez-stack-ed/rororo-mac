// CookieCapture.swift
// Domain — SwiftUI bridge that hosts a `WKWebView` pointed at Roblox's
// real login page, captures the `.ROBLOSECURITY` cookie post-login, and
// validates it via `RobloxApi.getUserProfile` before handing back the
// public-profile fields the UI needs to populate an Account record.
//
// Why we don't capture the password ourselves: Roblox's login form is
// the source of truth for the credential exchange (2FA, captchas, social
// auth). We never see the password. We only observe the cookie that
// Roblox sets in our private WKWebView data store, and only after Roblox
// has authenticated the user.
//
// Privacy posture: WKWebsiteDataStore is `.nonPersistent()` — when the
// sheet closes, the cookie store evaporates. The captured cookie value
// goes to Keychain via AccountStore.add and never lives on disk in plain
// form. The UI must surface this in the docs (Phase 7 PRIVACY.md).

import Foundation
import SwiftUI
import WebKit

public struct CookieCapture: NSViewControllerRepresentable {

    public struct CapturedAccount: Equatable, Sendable {
        public let cookie: String
        public let userId: String
        public let username: String
        public let displayName: String
    }

    public var onCaptured: (CapturedAccount) -> Void
    public var onCancel: () -> Void

    public init(
        onCaptured: @escaping (CapturedAccount) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.onCaptured = onCaptured
        self.onCancel = onCancel
    }

    public func makeNSViewController(context: Context) -> CookieCaptureViewController {
        CookieCaptureViewController(onCaptured: onCaptured, onCancel: onCancel)
    }

    public func updateNSViewController(_ nsViewController: CookieCaptureViewController, context: Context) {
        // One-shot capture; nothing to update post-mount.
    }
}

public final class CookieCaptureViewController: NSViewController, WKNavigationDelegate {

    private let webView: WKWebView
    private let onCaptured: (CookieCapture.CapturedAccount) -> Void
    private let onCancel: () -> Void
    private var didCapture = false
    private var didCancel = false

    public init(
        onCaptured: @escaping (CookieCapture.CapturedAccount) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let config = WKWebViewConfiguration()
        // Non-persistent store: cookies live only inside this WKWebView.
        // No leakage across launches; closing the sheet wipes them. This
        // also forces a fresh login each time — which is what we want.
        config.websiteDataStore = .nonPersistent()
        // Keep WKWebView's default User-Agent (a Safari shape) — Roblox's
        // login flow renders correctly under it. We only customize when
        // we hit Roblox's API directly via RobloxApi.
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.onCaptured = onCaptured
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        self.webView.navigationDelegate = self
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) {
        fatalError("CookieCaptureViewController does not support nib loading")
    }

    public override func loadView() {
        self.view = webView
        self.preferredContentSize = NSSize(width: 480, height: 720)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let url = URL(string: "https://www.roblox.com/login")!
        webView.load(URLRequest(url: url))
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        // Fire onCancel exactly once when the sheet closes without a
        // successful capture. UI's onCaptured handler closes the sheet
        // before viewWillDisappear runs, so we won't double-fire.
        if !didCapture, !didCancel {
            didCancel = true
            onCancel()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didCapture else { return }
        Task { @MainActor in
            await tryCapture()
        }
    }

    @MainActor
    private func tryCapture() async {
        guard !didCapture else { return }
        let cookies = await allCookies()
        guard let cookie = cookies.first(where: { $0.name == ".ROBLOSECURITY" })?.value,
              !cookie.isEmpty else {
            return
        }
        // Mark optimistically so a slower-arriving second navigation
        // doesn't kick off a duplicate validation. Reset on failure.
        didCapture = true
        do {
            let profile = try await RobloxApi.getUserProfile(cookie: cookie)
            onCaptured(.init(
                cookie: cookie,
                userId: String(profile.userId),
                username: profile.username,
                displayName: profile.displayName
            ))
        } catch {
            // Cookie was scraped but Roblox rejected it. Most likely the
            // user is on a transitional page where the cookie hasn't been
            // committed yet. Reset and let the next navigation retry.
            didCapture = false
        }
    }

    @MainActor
    private func allCookies() async -> [HTTPCookie] {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
    }
}
