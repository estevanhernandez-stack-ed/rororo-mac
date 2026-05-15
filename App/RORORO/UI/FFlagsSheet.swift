// FFlagsSheet.swift
// UI — the FFlags editor sheet (ADR 0011). Stacked layout: a preset
// picker on top (None + every FFlagPresetLibrary preset), an arbitrary
// key/value override editor below. Writes through to
// LaunchSettingsStore.activePreset + .fflags.
//
// Scope honesty: the subtitle says "Global" because the write surface
// (ClientAppSettings.json) is one file every Roblox instance reads —
// there is no per-account FFlag path (ADR 0002). Never reword this to
// imply per-instance behavior.
//
// Editor model: LaunchSettingsStore.fflags is an unordered dict; the
// sheet keeps an ordered [EditorRow] for stable identity while typing
// and commits parsed rows back to the store on every edit. Rows that
// don't parse (e.g. "abc" typed into an Int) stay visible with an inline
// error and are simply excluded from the committed dict.

import SwiftUI

struct FFlagsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared

    @State private var rows: [EditorRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    presetSection
                    Divider()
                    overridesSection
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 520, idealHeight: 620)
        .background(Theme.Color.bgPage)
        .onAppear { rows = Self.rowsFromStore(launchSettings.fflags) }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FFlags")
                .font(Theme.Font.heading1)
                .foregroundStyle(Theme.Color.fg1)
            Text("Global — applies to every Roblox instance at launch.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg3)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.productTeal)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Preset section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("PRESET")
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg3)
                .tracking(1.4)
            HStack(spacing: Theme.Spacing.sm) {
                presetCard(
                    title: "None",
                    summary: "Only your overrides below",
                    isActive: launchSettings.activePreset == nil,
                    select: { launchSettings.setActivePreset(nil) }
                )
                ForEach(FFlagPresetLibrary.all) { preset in
                    presetCard(
                        title: preset.displayName,
                        summary: preset.summary,
                        isActive: launchSettings.activePreset == preset.id,
                        select: { launchSettings.setActivePreset(preset.id) }
                    )
                }
            }
        }
    }

    private func presetCard(
        title: String,
        summary: String,
        isActive: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(isActive ? Theme.Color.brandCyan : Theme.Color.fg1)
                Text(summary)
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(
                        isActive ? Theme.Color.brandCyan : Theme.Color.bgRaised,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overrides section

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("YOUR OVERRIDES")
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.fg3)
                    .tracking(1.4)
                Spacer()
                Button {
                    rows.append(EditorRow(key: "", type: .bool, rawValue: "true"))
                } label: {
                    Label("Add flag", systemImage: "plus")
                        .font(Theme.Font.bodySmall)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Color.productTeal)
            }

            if rows.isEmpty {
                Text("No overrides. Pick a preset above, or add a flag to set one yourself. Overrides win over the preset on any key they share.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            } else {
                ForEach($rows) { $row in
                    overrideRow($row)
                }
            }
        }
    }

    private func overrideRow(_ row: Binding<EditorRow>) -> some View {
        let risk = RiskyFFlagPatterns.risk(for: row.wrappedValue.key)
        let parseError = Self.parseError(for: row.wrappedValue)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                TextField("FFlagName", text: row.key)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .onChange(of: row.wrappedValue.key) { _, _ in commit() }

                TextField("value", text: row.rawValue)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .frame(width: 88)
                    .onChange(of: row.wrappedValue.rawValue) { _, _ in commit() }

                Picker("", selection: row.type) {
                    ForEach(EditorRow.ValueType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .onChange(of: row.wrappedValue.type) { _, _ in commit() }

                if let risk {
                    Text("⚠ \(risk.rawValue)")
                        .font(Theme.Font.monoMicro)
                        .foregroundStyle(Theme.Color.stateWarn)
                        .help("This flag name matches a known-risky pattern (\(risk.rawValue)). Some risky flags can be bannable in certain games — see ADR 0006. Saved anyway; your call.")
                }

                Button {
                    let id = row.wrappedValue.id
                    rows.removeAll { $0.id == id }
                    commit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Color.fg3)
                }
                .buttonStyle(.plain)
            }
            if let parseError {
                Text(parseError)
                    .font(Theme.Font.monoMicro)
                    .foregroundStyle(Theme.Color.stateDanger)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - Commit

    private func commit() {
        launchSettings.setFFlags(Self.storeFromRows(rows))
    }

    // MARK: - Editor model (pure — unit-tested in FFlagsSheetTests)

    struct EditorRow: Identifiable {
        let id = UUID()
        var key: String
        var type: ValueType
        var rawValue: String

        enum ValueType: String, CaseIterable {
            case bool = "Bool"
            case int = "Int"
            case double = "Double"
            case string = "String"
        }
    }

    /// Build editor rows from the persisted dict, sorted by key for a
    /// stable display order (the dict itself is unordered).
    static func rowsFromStore(_ flags: [String: AnyCodableValue]) -> [EditorRow] {
        flags.sorted { $0.key < $1.key }.map { key, value in
            switch value {
            case .bool(let b):   return EditorRow(key: key, type: .bool,   rawValue: b ? "true" : "false")
            case .int(let i):    return EditorRow(key: key, type: .int,    rawValue: String(i))
            case .double(let d): return EditorRow(key: key, type: .double, rawValue: String(d))
            case .string(let s): return EditorRow(key: key, type: .string, rawValue: s)
            }
        }
    }

    /// Parse editor rows back into the persisted dict. Rows with an empty
    /// key or an unparseable value are dropped (they stay in the UI with
    /// an inline error via `parseError`). On a duplicate key the last row
    /// wins — consistent with "the dict is keyed."
    static func storeFromRows(_ rows: [EditorRow]) -> [String: AnyCodableValue] {
        var out: [String: AnyCodableValue] = [:]
        for row in rows {
            guard !row.key.isEmpty, let value = parsedValue(for: row) else { continue }
            out[row.key] = value
        }
        return out
    }

    /// The parsed AnyCodableValue for a row, or nil when the raw text
    /// doesn't fit the chosen type.
    static func parsedValue(for row: EditorRow) -> AnyCodableValue? {
        switch row.type {
        case .bool:
            switch row.rawValue.lowercased() {
            case "true":  return .bool(true)
            case "false": return .bool(false)
            default:      return nil
            }
        case .int:
            return Int(row.rawValue).map(AnyCodableValue.int)
        case .double:
            return Double(row.rawValue).map(AnyCodableValue.double)
        case .string:
            return .string(row.rawValue)
        }
    }

    /// Inline validation message for a row, or nil when the row is valid.
    static func parseError(for row: EditorRow) -> String? {
        if row.key.isEmpty { return "Flag name can't be empty." }
        if parsedValue(for: row) == nil {
            switch row.type {
            case .bool:   return "Bool must be \"true\" or \"false\"."
            case .int:    return "Not a whole number."
            case .double: return "Not a number."
            case .string: return nil
            }
        }
        return nil
    }
}
