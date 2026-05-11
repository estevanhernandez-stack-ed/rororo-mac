// AutoKeysRecorderV2Sheet.swift
// Modal recorder for one account's full-fidelity action stream
// (ADR 0007 Decision 3 / Wave D-3.4). Record → user performs the
// sequence in Roblox → Stop → review + Save / Discard.
//
// Frontmost-only capture (Decision 3): the recorder only ingests events
// while the target Roblox PID is frontmost. While the user is inside
// RORORO (this sheet visible), capture pauses — the indicator surfaces
// "PAUSED — Roblox not frontmost" so the user knows to Cmd-Tab back.
//
// The per-row chip's entry point. Legacy step-list sequences from
// ADR 0004 still load (via `AutoKeysSequence.legacy`) and run via the
// cycler's legacy variant path — but they can no longer be edited
// in-place; re-recording in this sheet produces a stream variant that
// overwrites cleanly. D-3.6 removed the legacy sheet from the codebase.
//
// View-model lives in this file (private to the sheet) — owns an
// `ActionStreamRecorder`, polls its async state at 10 Hz, exposes
// SwiftUI-friendly properties. Persistence funnels through the
// existing `AccountStore.setAutoKeys` so legacy + stream variants
// share one storage path.

import AppKit
import CoreGraphics
import Observation
import SwiftUI

struct AutoKeysRecorderV2Sheet: View {

    @Binding var isPresented: Bool
    let account: Account

    @State private var viewModel: RecorderV2ViewModel
    @State private var capturingHotkey: Bool = false

    init(isPresented: Binding<Bool>, account: Account) {
        self._isPresented = isPresented
        self.account = account
        self._viewModel = State(initialValue: RecorderV2ViewModel(account: account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            divider
            legacyNotice
            hotkeySection
            statusBlock
            recordButton
            counters
            divider
            postRecordControls
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 520, height: 620)
        .background(Theme.Color.bgPage)
        .background(KeyCaptureRepresentable(capturing: $capturingHotkey) { code, mods in
            // Reject bare keys — a 4-key chord avoids accidents in
            // game; we won't store a hotkey without modifiers.
            guard mods != 0 else {
                capturingHotkey = false
                return
            }
            viewModel.setHotkey(KillKeyCombo(keyCode: code, modifiers: mods))
            capturingHotkey = false
        })
        .onDisappear {
            // Hard-stop the recorder if the sheet is dismissed mid-record.
            Task { await viewModel.tearDown() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Record auto-keys for \(account.displayName)")
                .font(Theme.Font.heading2)
                .foregroundStyle(Theme.Color.fg1)
            Text("Click Record to arm. Cmd-Tab to Roblox. Press your record hotkey to start, do the thing, press it again to stop. The hotkey itself is filtered from the captured stream — Cmd-Tab presses too.")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.Color.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hotkeySection: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECORD HOTKEY")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
                    .tracking(0.7)
                Text(prettyKeyCombo(
                    keyCode: viewModel.hotkey.keyCode,
                    modifiers: viewModel.hotkey.modifiers
                ))
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.fg1)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 4)
                    .background(Theme.Color.bgRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            Spacer()
            Button(capturingHotkey ? "Press chord…" : "Change") {
                capturingHotkey = true
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.phase == .recording_armed || viewModel.phase == .recording_active)
        }
    }

    @ViewBuilder
    private var legacyNotice: some View {
        if let existing = account.autoKeys, existing.isLegacy, !existing.isEmpty {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Theme.Color.stateWarn)
                Text("This account has a legacy \(existing.steps.count)-key recording. Saving here overwrites it with a full action stream — keys + mouse.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Color.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }

    private var statusBlock: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle().fill(statusDotColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Color.fg1)
                .tracking(0.6)
                .textCase(.uppercase)
            Spacer()
            if viewModel.phase == .recording_active && viewModel.isCapturePaused {
                Text("Roblox not frontmost — Cmd-Tab to resume capture")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.stateWarn)
            }
        }
    }

    private var recordButton: some View {
        HStack {
            Button(action: { Task { await primaryAction() } }) {
                Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(primaryButtonTint)
            .disabled(viewModel.preflightMessage != nil)
            // Hint about the hotkey when armed — the user is going to
            // Cmd-Tab away, so the chord display they just read is the
            // one they need to remember.
            if viewModel.phase == .recording_armed {
                Text("Now Cmd-Tab to Roblox and press the chord")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg3)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var counters: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("ACTIONS")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
                    .tracking(0.7)
                Spacer()
                Text("\(viewModel.actionCount) / \(AutoKeysSequence.maxActionCount)")
                    .font(Theme.Font.mono)
                    .foregroundStyle(viewModel.didCap ? Theme.Color.stateDanger : Theme.Color.fg1)
            }
            HStack {
                Text("ELAPSED")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.fg2)
                    .tracking(0.7)
                Spacer()
                Text(formatSeconds(viewModel.elapsed))
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.fg1)
            }
            if viewModel.didCap {
                Text("Hit the \(AutoKeysSequence.maxActionCount)-action cap — further events are dropped. Stop and re-record a shorter sequence if you need a shorter loop.")
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.stateDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preflight = viewModel.preflightMessage {
                Text(preflight)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(Theme.Color.stateDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var postRecordControls: some View {
        if viewModel.phase == .stopped {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("NAME")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg2)
                        .tracking(0.7)
                    TextField("e.g. Combat rotation", text: $viewModel.macroName)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.body)
                    Text("Optional. Shows in the row badge + sharing picker. Leave blank to just see action count.")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.Color.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $viewModel.isShared) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share this recording")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Color.fg1)
                        Text("Other accounts can opt in to use this recording instead of recording their own.")
                            .font(Theme.Font.bodySmall)
                            .foregroundStyle(Theme.Color.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                Task {
                    await viewModel.discard()
                    isPresented = false
                }
            }
            Spacer()
            if viewModel.phase == .stopped && viewModel.actionCount > 0 {
                Button("Save") {
                    viewModel.save()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.Color.bgRaised).frame(height: 1)
    }

    // MARK: - Derived

    private var statusText: String {
        switch viewModel.phase {
        case .idle:
            return "Ready to record"
        case .recording_armed:
            return "Armed — press chord in Roblox to start"
        case .recording_active:
            return viewModel.isCapturePaused ? "Paused (Roblox not frontmost)" : "Recording"
        case .stopped:
            if viewModel.actionCount == 0 { return "Nothing captured" }
            return "Stopped — \(viewModel.actionCount) actions"
        }
    }

    private var statusDotColor: Color {
        switch viewModel.phase {
        case .idle:             return Theme.Color.fg3
        case .recording_armed:  return Theme.Color.stateWarn
        case .recording_active: return viewModel.isCapturePaused ? Theme.Color.stateWarn : Theme.Color.stateOk
        case .stopped:          return Theme.Color.stateOk
        }
    }

    private var primaryButtonTitle: String {
        switch viewModel.phase {
        case .idle:             return "Record"
        case .recording_armed:  return "Cancel"
        case .recording_active: return "Stop"
        case .stopped:          return viewModel.actionCount == 0 ? "Try again" : "Re-record"
        }
    }

    private var primaryButtonIcon: String {
        switch viewModel.phase {
        case .idle:             return "record.circle"
        case .recording_armed:  return "xmark.circle"
        case .recording_active: return "stop.circle.fill"
        case .stopped:          return "arrow.counterclockwise"
        }
    }

    private var primaryButtonTint: Color {
        switch viewModel.phase {
        case .recording_active: return Theme.Color.stateDanger
        default:                return Theme.Color.brandCyan
        }
    }

    private func primaryAction() async {
        switch viewModel.phase {
        case .idle, .stopped:
            await viewModel.startRecording()
        case .recording_armed, .recording_active:
            await viewModel.stopRecording()
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

// MARK: - View model

@MainActor
@Observable
private final class RecorderV2ViewModel {

    enum Phase: Equatable {
        case idle
        /// Recorder started, waiting for the user to press the hotkey
        /// from Roblox. Cmd-Tab + chord transitions to active.
        case recording_armed
        /// Capture is live — events flow into the action stream.
        case recording_active
        case stopped
    }

    var phase: Phase = .idle
    var actionCount: Int = 0
    var elapsed: TimeInterval = 0
    var isCapturePaused: Bool = false
    var didCap: Bool = false
    var isShared: Bool = false
    /// User-typed label for this recording. Persisted on Save iff the
    /// trimmed value is non-empty (collapse-to-nil happens inside
    /// `AutoKeysSequence`). Pre-populates from the existing sequence's
    /// name when re-recording so the user can keep it or change it.
    var macroName: String = ""
    var preflightMessage: String?
    var hotkey: KillKeyCombo

    private let account: Account
    private let store: AccountStore
    private let runningTracker: RunningAccountTracker
    private let windowRectTracker: WindowRectTracker
    private let settings: LaunchSettingsStore
    private let recorder: ActionStreamRecorder
    private var pollTask: Task<Void, Never>?
    private var capturedActions: [AutoKeysAction] = []

    init(account: Account) {
        self.account = account
        self.store = .shared
        self.runningTracker = .shared
        self.windowRectTracker = .shared
        self.settings = .shared
        self.hotkey = LaunchSettingsStore.shared.recorderHotkey
        // Pre-populate macroName from an existing stream recording so
        // the user can keep the label across a re-record without
        // retyping. Legacy variants have no name.
        if let existing = account.autoKeys, let n = existing.name {
            self.macroName = n
        }
        self.recorder = ActionStreamRecorder(
            source: NSEventRecorderEventSource(),
            tracker: .shared,
            frontmost: NSWorkspaceFrontmostAppProvider()
        )
    }

    func setHotkey(_ combo: KillKeyCombo) {
        hotkey = combo
        settings.setRecorderHotkey(combo)
    }

    func startRecording() async {
        preflightMessage = nil
        // Permission preflight — same TCC buckets as the cycler.
        // Accessibility is needed for the cycler's later replay; Input
        // Monitoring is needed for the global NSEvent monitor.
        if AutoKeysPermissions.accessibilityStatus() != .granted {
            preflightMessage = "Recorder needs Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility and try again."
            return
        }
        if AutoKeysPermissions.inputMonitoringStatus() != .granted {
            preflightMessage = "Recorder needs Input Monitoring to capture events globally. Grant it in System Settings → Privacy & Security → Input Monitoring and try again."
            return
        }

        // Make sure the account has a running Roblox window. The
        // frontmost-only filter means there's no point starting capture
        // against a pid that doesn't exist — the user would see
        // permanent "paused" with no way to record anything.
        runningTracker.backfillFromRunningProcesses()
        guard let pid = runningTracker.pid(for: account.userId) else {
            preflightMessage = "No running Roblox window for this account. Launch \(account.displayName) from the row first, then re-open this sheet."
            return
        }

        // Refresh the rect cache so the recorder can translate mouse
        // coords from the first action. The cycler usually does this on
        // focus, but the recorder runs without the cycler.
        await windowRectTracker.refresh(pid: pid)

        capturedActions = []
        actionCount = 0
        elapsed = 0
        isCapturePaused = false
        didCap = false
        phase = .recording_armed

        // Pass the configured hotkey so the recorder enters .armed —
        // user presses chord from Roblox to transition to active.
        await recorder.start(targetPid: pid, hotkey: hotkey)

        // Poll the recorder at 10 Hz. Mirror the actor's status to the
        // sheet's Phase so armed→active and active→stopped transitions
        // (driven by the hotkey, not by sheet buttons) flip the UI.
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = await self.recorder.currentStatus()
                self.actionCount = await self.recorder.currentCount()
                self.elapsed = await self.recorder.elapsed()
                self.isCapturePaused = await self.recorder.isCapturePaused()
                self.didCap = await self.recorder.didReachCap()
                switch status {
                case .armed:
                    self.phase = .recording_armed
                case .active:
                    self.phase = .recording_active
                case .stopped:
                    // Recorder transitioned itself via the hotkey.
                    // Pull the captured actions and stop polling.
                    self.capturedActions = await self.recorder.stop()
                    self.actionCount = self.capturedActions.count
                    self.elapsed = await self.recorder.elapsed()
                    self.phase = .stopped
                    return
                case .idle:
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopRecording() async {
        pollTask?.cancel()
        pollTask = nil
        capturedActions = await recorder.stop()
        actionCount = capturedActions.count
        // Pull one last elapsed read so the post-record number is fresh.
        elapsed = await recorder.elapsed()
        phase = .stopped
    }

    func save() {
        guard !capturedActions.isEmpty else { return }
        guard let sequence = AutoKeysSequence(
            actions: capturedActions,
            isShared: isShared,
            name: macroName
        ) else {
            preflightMessage = "Recording exceeded the \(AutoKeysSequence.maxActionCount)-action cap. Re-record shorter."
            return
        }
        store.setAutoKeys(userId: account.userId, sequence: sequence)
    }

    func discard() async {
        await tearDown()
    }

    func tearDown() async {
        pollTask?.cancel()
        pollTask = nil
        if phase == .recording_armed || phase == .recording_active {
            _ = await recorder.stop()
        }
    }
}
