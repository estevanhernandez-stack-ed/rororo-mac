# RORORO Mac

Mac-native multi-Roblox launcher. Account vault + multi-instance support. Native Swift/SwiftUI.

> Sibling to [ROROROblox](https://github.com/estevanhernandez-stack-ed/ROROROblox) (Windows). Same product, different platform; the auth-ticket → launcher URI flow is preserved byte-identical so accounts can move between OSes later.

## Status

Phase 0 — repo skeleton + blank window. Subsequent phases (foundation primitives, Roblox API, multi-instance coordinator, account vault, UI, Sparkle, docs) ship per the implementation plan.

`v0.1.0` ships after the four-step bootstrap (Sparkle EdDSA keypair, Apple Developer ID cert, notarization creds, GitHub Pages enablement). See `tools/release/README.md` (lands at Phase 6).

## Build

```sh
cd App
xcodegen generate
xcodebuild -scheme RORORO build
```

## Hard rules

- No anti-detection logic. `sem_unlink` is a public POSIX call; that's all we use.
- No telemetry. GitHub Releases anonymous download counts only.
- No password capture. WKWebView shows Roblox's own login; we capture only the `.ROBLOSECURITY` cookie.
- No secrets in repo. Sparkle EdDSA private key + Apple Developer ID cert + notarization creds in 1Password / GitHub Secrets only.

## License

MIT — see `LICENSE`.
