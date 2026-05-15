// FFlagPreset.swift
// Domain — a named curated FFlag bundle plus the metadata the FFlags
// sheet's preset card needs. Created only by FFlagPresetLibrary; the
// curated bundle constants (LowResourceFFlags, PerformanceFFlags) live
// in their own files and this just wraps them.

import Foundation

public struct FFlagPreset: Identifiable, Sendable {
    public let id: FFlagPresetID
    /// Card title, e.g. "Low-resource".
    public let displayName: String
    /// One-line card body, e.g. "AFK / multi-instance grind".
    public let summary: String
    /// The curated flag dictionary merged in at launch time.
    public let bundle: [String: AnyCodableValue]

    public init(
        id: FFlagPresetID,
        displayName: String,
        summary: String,
        bundle: [String: AnyCodableValue]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.bundle = bundle
    }
}
