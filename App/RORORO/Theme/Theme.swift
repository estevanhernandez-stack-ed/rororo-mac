// Theme.swift
// 626Labs design tokens, mapped to SwiftUI types.
//
// Adapted from macRo's `MacRoTheme.swift`. Same brand surfaces (cyan +
// magenta paired duotone, deep navy field, product teal CTA, three font
// families) — drops editor-specific tokens (timeline lane geometry, gate
// shapes) since RORORO has no recorder/editor surface.
//
// Token source of truth: ~/projects/626labs-design/colors_and_type.css
// Skill: ~/.claude/skills/626labs-design/

import SwiftUI

enum Theme {

    // MARK: - Color

    enum Color {
        // Brand — paired duotone (cyan + magenta).
        static let brandCyan    = SwiftUI.Color(hex: 0x17D4FA)
        static let brandMagenta = SwiftUI.Color(hex: 0xF22F89)

        // Product-specific — teal CTA accent.
        static let productTeal  = SwiftUI.Color(hex: 0x2EE6C9)

        // Surface field — deep navy pair from the brand system.
        static let bgPage       = SwiftUI.Color(hex: 0x091023) // page / "void"
        static let bgSurface    = SwiftUI.Color(hex: 0x192E44)
        static let bgRaised     = SwiftUI.Color(hex: 0x223A54)

        // Foreground.
        static let fg1          = SwiftUI.Color(hex: 0xFFFFFF)
        static let fg2          = SwiftUI.Color(hex: 0xC4CDDA)
        static let fg3          = SwiftUI.Color(hex: 0x8E9BAD)

        // Semantic state colors. Don't pair with brand cyan/magenta —
        // these are state signals, not brand surfaces; mixing dilutes both.
        static let stateOk      = SwiftUI.Color(hex: 0x2BD99A)
        static let stateWarn    = SwiftUI.Color(hex: 0xFFB454)
        static let stateDanger  = SwiftUI.Color(hex: 0xFF5472)
        static let stateInfo    = brandCyan

        // Tray status ring colors — cyan = multi-instance ON,
        // slate = OFF, magenta = error.
        static let trayOn       = brandCyan
        static let trayOff      = fg3
        static let trayError    = brandMagenta
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let pill: CGFloat = 999
    }

    // MARK: - Font

    enum Font {
        // Display — Space Grotesk. Falls back to system when not installed.
        static let display     = SwiftUI.Font.custom("Space Grotesk", size: 40, relativeTo: .largeTitle)
            .weight(.bold)
        static let heading1    = SwiftUI.Font.custom("Space Grotesk", size: 32, relativeTo: .title)
            .weight(.bold)
        static let heading2    = SwiftUI.Font.custom("Space Grotesk", size: 22, relativeTo: .title2)
            .weight(.semibold)

        // Body — Inter for UI prose.
        static let body        = SwiftUI.Font.custom("Inter", size: 16, relativeTo: .body)
        static let bodySmall   = SwiftUI.Font.custom("Inter", size: 14, relativeTo: .callout)

        // Code / meta — JetBrains Mono. Uppercase + 0.12em tracking on
        // small labels per design spec.
        static let mono        = SwiftUI.Font.custom("JetBrains Mono", size: 13, relativeTo: .caption)
        static let monoMicro   = SwiftUI.Font.custom("JetBrains Mono", size: 11, relativeTo: .caption2)
            .weight(.semibold)
    }
}

// MARK: - Hex helper

private extension SwiftUI.Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
