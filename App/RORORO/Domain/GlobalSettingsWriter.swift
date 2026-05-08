// GlobalSettingsWriter.swift
// Domain — surgical XML edits to Roblox's `GlobalBasicSettings_<N>.xml`.
//
// This file is the user-prefs file Roblox writes when you change in-game
// settings (graphics quality, sensitivity, framerate cap, etc.). On macOS
// it lives at `~/Library/Roblox/GlobalBasicSettings_13.xml`. It is NOT an
// FFlag file — Hyperion locks the FFlag write surface, but this XML lives
// on a separate channel the engine reads at startup. Cross-platform: the
// same schema is used on Windows (`%LOCALAPPDATA%\Roblox\...`) and via the
// Sober Flatpak on Linux. The Windows recipe for the framerate cap
// (`<int name="FramerateCap">N</int>`) transfers to Mac unchanged.
//
// Posture (per the AppleBlox spike, 2026-05-08):
//   - Surgical edit: change ONLY the requested element; preserve every
//     other user-set value (quality, sensitivity, fullscreen, etc.).
//   - Schema-version glob: `GlobalBasicSettings_*.xml`, highest number wins.
//     Insurance against Roblox bumping `_13` → `_14`.
//   - Atomic write (tmp + rename) via Data.write(.atomic).
//   - Write-on-every-launch: Roblox overwrites on quit, we re-assert on
//     the next launch. Caller is responsible for the timing.
//
// Multi-instance reality: this file is per-user, NOT per-instance. Setting
// FramerateCap=20 caps every running Roblox instance uniformly. For
// per-account divergence (different caps simultaneously), a per-process
// throttle is needed — this writer alone can't differentiate live.

import Foundation

public enum GlobalSettingsWriter {

    public enum WriterError: Error, Equatable {
        case settingsFileNotFound(searchedDir: String)
        case parseFailure(reason: String)
        case framerateCapElementMissing
        case writeFailed(underlying: String)
    }

    /// Default search directory on macOS — `~/Library/Roblox/`.
    /// Override via `directoryOverride` in tests.
    public static var defaultSearchDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Roblox", isDirectory: true)
    }

    /// Locate the highest-numbered GlobalBasicSettings file in `directory`.
    /// e.g., among `GlobalBasicSettings_12.xml` and `GlobalBasicSettings_13.xml`,
    /// returns the path to the `_13` file. Returns nil if no matching file.
    public static func resolveSettingsFile(in directory: URL = defaultSearchDirectory) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let pattern = try? NSRegularExpression(pattern: #"^GlobalBasicSettings_(\d+)\.xml$"#)
        var best: (url: URL, version: Int)? = nil
        for entry in entries {
            let name = entry.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = pattern?.firstMatch(in: name, range: range),
                  match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: name),
                  let version = Int(name[captured]) else {
                continue
            }
            if best == nil || version > best!.version {
                best = (entry, version)
            }
        }
        return best?.url
    }

    /// Read the current FramerateCap value from the settings file.
    /// Returns nil if the element is missing (Roblox always writes it
    /// on first run, so missing usually means corrupted file).
    public static func currentFramerateCap(
        directory: URL = defaultSearchDirectory
    ) throws -> Int? {
        let url = try requireSettingsFile(in: directory)
        let document = try parseDocument(at: url)
        return try framerateCapElement(in: document)?.stringValue.flatMap(Int.init)
    }

    /// Surgically set FramerateCap to `value`. Preserves every other
    /// element in the document. Atomic write via `Data.write(.atomic)`.
    public static func setFramerateCap(
        _ value: Int,
        directory: URL = defaultSearchDirectory
    ) throws {
        let url = try requireSettingsFile(in: directory)
        let document = try parseDocument(at: url)
        guard let element = try framerateCapElement(in: document) else {
            throw WriterError.framerateCapElementMissing
        }
        element.stringValue = String(value)

        let data = document.xmlData(options: [.nodePreserveWhitespace, .nodePreserveCDATA])
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw WriterError.writeFailed(underlying: String(describing: error))
        }
    }

    // MARK: - Internals

    private static func requireSettingsFile(in directory: URL) throws -> URL {
        guard let url = resolveSettingsFile(in: directory) else {
            throw WriterError.settingsFileNotFound(searchedDir: directory.path)
        }
        return url
    }

    private static func parseDocument(at url: URL) throws -> XMLDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WriterError.parseFailure(reason: "read failed: \(error)")
        }
        do {
            return try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodePreserveCDATA])
        } catch {
            throw WriterError.parseFailure(reason: String(describing: error))
        }
    }

    /// Find `<int name="FramerateCap">N</int>` anywhere in the document.
    /// XPath: any `int` element with attribute `name="FramerateCap"`.
    private static func framerateCapElement(in document: XMLDocument) throws -> XMLElement? {
        let nodes: [XMLNode]
        do {
            nodes = try document.nodes(forXPath: "//int[@name='FramerateCap']")
        } catch {
            throw WriterError.parseFailure(reason: "xpath failed: \(error)")
        }
        return nodes.compactMap { $0 as? XMLElement }.first
    }
}
