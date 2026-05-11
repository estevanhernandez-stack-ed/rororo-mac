// MacroLibrarySheet.swift
// Modal management view for the macro library (Wave D-4.5). Lists
// every macro in `MacroStore`, with inline rename, share toggle,
// and delete. The visible payoff for the Slope D-4 library refactor
// — before D-4.5 the user had to discover macros via per-account
// chips; here they see everything in one place and edit metadata
// without re-recording.
//
// Triggered from the cycler toolbar's chevron menu ("Macros…").
//
// Edit flow:
//   - Tap pencil icon next to a macro name → name turns into a
//     TextField, user types + Enter → commits via MacroStore.rename.
//   - Share toggle on each row binds to MacroStore.setShared.
//   - Trash icon → confirmation alert → MacroStore.delete +
//     AccountStore.clearReferencesToMacro cascades.

import SwiftUI

struct MacroLibrarySheet: View {

    @Binding var isPresented: Bool

    private let store = MacroStore.shared
    private let accountStore = AccountStore.shared

    @State private var editingMacroId: String?
    @State private var editingName: String = ""
    @State private var pendingDelete: Macro?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            divider
            if store.macros.isEmpty {
                emptyState
            } else {
                macroList
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 680, height: 560)
        .background(Theme.Color.bgPage)
        .alert(
            "Delete macro?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { newValue in if !newValue { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let m = pendingDelete {
                Text("\"\(m.name)\" will be removed from the library. Any account currently bound to it will fall back to the global default (or skip if none).")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Macros")
                    .font(Theme.Font.heading2)
                    .foregroundStyle(Theme.Color.fg1)
                Spacer()
                Text("\(store.macros.count) total")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }
            Text("Every recording across every account. Rename inline, toggle sharing, or delete. Recording new macros happens on the per-account row chips.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Color.fg3)
            Text("No macros yet")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg2)
            Text("Click the auto-keys chip on any account row to record your first one.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var macroList: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(store.macros, id: \.id) { macro in
                    macroRow(macro)
                        .padding(Theme.Spacing.md)
                        .background(Theme.Color.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            }
        }
    }

    private func macroRow(_ macro: Macro) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: macro.isLegacy ? "keyboard.badge.ellipsis" : "keyboard.fill")
                .font(.system(size: 16))
                .foregroundStyle(macro.isLegacy ? Theme.Color.stateWarn : Theme.Color.brandCyan)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                if editingMacroId == macro.id {
                    TextField("Name", text: $editingName, onCommit: {
                        commitRename(macro)
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.body)
                } else {
                    HStack(spacing: 4) {
                        Text(macro.name)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Color.fg1)
                        Button {
                            startRename(macro)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Color.fg3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(subtitle(for: macro))
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(countLabel(for: macro))
                .font(Theme.Font.monoMicro)
                .foregroundStyle(Theme.Color.fg2)
                .tracking(0.4)

            Toggle("", isOn: Binding(
                get: { macro.isShared },
                set: { store.setShared(id: macro.id, isShared: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help("Toggle off to hide this macro from other accounts' pickers.")

            Button {
                pendingDelete = macro
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.stateDanger)
            }
            .buttonStyle(.plain)
            .help("Delete this macro. Accounts bound to it will fall back to the global default.")
        }
    }

    private var footer: some View {
        HStack {
            Button("Done") {
                if editingMacroId != nil {
                    // Commit any in-flight rename before closing.
                    if let id = editingMacroId,
                       let m = store.macros.first(where: { $0.id == id }) {
                        commitRename(m)
                    }
                }
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.Color.bgRaised).frame(height: 1)
    }

    // MARK: - Helpers

    private func subtitle(for macro: Macro) -> String {
        let ownerStr: String = {
            guard let id = macro.ownerUserId else { return "no owner" }
            if let owner = accountStore.accounts.first(where: { $0.id == id }) {
                return "from \(owner.displayName)"
            }
            return "owner missing"
        }()
        let usedBy = accountStore.accounts.filter { $0.activeMacroId == macro.id }.count
        if usedBy == 0 {
            return "\(ownerStr) · unused"
        } else if usedBy == 1 {
            return "\(ownerStr) · used by 1 account"
        }
        return "\(ownerStr) · used by \(usedBy) accounts"
    }

    private func countLabel(for macro: Macro) -> String {
        let count: Int
        switch macro.variant {
        case let .legacy(steps): count = steps.count
        case let .stream(actions): count = actions.count
        }
        let unit = macro.isLegacy ? "STEPS" : "ACTS"
        return "\(count) \(unit) · \(formatSeconds(macro.sequence.totalDuration))"
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            return String(format: "%.1fM", seconds / 60)
        }
        return String(format: "%.1fS", seconds)
    }

    private func startRename(_ macro: Macro) {
        editingMacroId = macro.id
        editingName = macro.name
    }

    private func commitRename(_ macro: Macro) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.rename(id: macro.id, to: trimmed)
        }
        editingMacroId = nil
        editingName = ""
    }

    private func confirmDelete() {
        guard let m = pendingDelete else { return }
        accountStore.clearReferencesToMacro(id: m.id)
        store.delete(id: m.id)
        pendingDelete = nil
    }
}
