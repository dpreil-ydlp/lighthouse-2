import AppKit
import LighthouseCore
import SwiftUI

/// Settings (SPEC §6.6).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SourcesSettings().tabItem { Label("Sources", systemImage: "tray.full") }
            UsageSettingsView()
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.33percent") }
            OpenInSettings().tabItem { Label("Open-in", systemImage: "arrow.up.forward.app") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            SummarySettingsView()
                .tabItem { Label("Summaries", systemImage: "sparkles") }
            ProjectsSettings().tabItem { Label("Projects", systemImage: "folder") }
        }
        .frame(width: 520, height: 380)
    }
}

struct StagedSettings: View {
    let title: String
    let detail: String
    var body: some View {
        Form {
            Section(title) { Text(detail).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show lowest usage left in menu bar", isOn: Binding(
                    get: { model.usageSettings.showWorstPercent }, set: { model.setShowWorstPercent($0) }))
                let _ = model.loginItemTick
                Toggle("Open Lighthouse at login", isOn: Binding(get: { LoginItem.isOn }, set: { model.setLoginItem($0) }))
                if LoginItem.status == .requiresApproval {
                    Text(LoginItem.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if LoginItem.lastChangeFailed {
                    Text("Failed. Use System Settings › Login Items.").font(.system(size: 11)).foregroundStyle(.orange)
                }
                Picker("Toggle panel hotkey", selection: Binding(get: { model.appSettings.hotkey }, set: { model.setHotkey($0) })) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.hotkeyStatus != 0 {
                    Text("In use by another app.").font(.system(size: 11)).foregroundStyle(.orange)
                } else if model.appSettings.hotkey == .optionSpace && Hotkey.chatGPTInstalled {
                    Text("ChatGPT also uses ⌥Space.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                LabeledContent("Version") {
                    Text(AppIdentity.versionLine()).textSelection(.enabled).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                LabeledContent("Store") {
                    Text(model.storePath).textSelection(.enabled).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            UpdateSettingsSection()
            Section("Shelf") {
                Picker("Keep in Recently completed for", selection: Binding(
                    get: { model.appSettings.recentlyCompletedHours }, set: { model.setRecentlyCompletedHours($0) })) {
                    ForEach(ShelfOptions.hourChoices, id: \.self) { Text(Self.hoursLabel($0)).tag($0) }
                }
                Toggle("Show Quiet projects", isOn: Binding(get: { model.appSettings.showQuiet }, set: { model.setShowQuiet($0) }))
            }
            Section("Privacy") {
                Text("Stores metadata only, never message text. Usage checks call api.anthropic.com and chatgpt.com; update checks call api.github.com. Summaries send recent text to the provider you choose.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralSettings {
    static func hoursLabel(_ hours: Int) -> String {
        hours % 24 == 0 && hours >= 48 ? "\(hours / 24) days" : "\(hours) hours"
    }
}

struct SourcesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(model.snapshot.statuses, id: \.source) { status in
                Section(status.source.displayName) {
                    if let error = status.error {
                        // One line per source outage (SPEC §8, §10); outages never notify.
                        Label("Source unavailable · \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    LabeledContent("Last read", value: "\(Age.short(status.lastReadAt, now: model.now)) ago")
                    LabeledContent("Threads", value: "\(status.threadCount)")
                    if status.source == .t3 {
                        LabeledContent("Coverage", value: status.filesIndexed > 0 ? "Read in place, read-only" : "Not read yet")
                    } else {
                        LabeledContent("Coverage", value: "\(status.filesIndexed) of \(status.filesInWindow) files indexed (last 30 days)")
                    }
                    if status.filesNotIndexed > 0 {
                        LabeledContent("Not indexed", value: "\(status.filesNotIndexed) older files")
                    }
                    if status.skippedLines > 0 {
                        LabeledContent("Skipped lines", value: "\(status.skippedLines) over 1 MB")
                    }
                }
            }
            if let error = model.storeError {
                Section("Store") { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            NudgeSettings()
        }
        .formStyle(.grouped)
    }
}

/// SPEC 2.11: the one switch that lets Lighthouse send anything into a thread.
struct NudgeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Nudge stalled T3 Code threads", isOn: Binding(get: { model.appSettings.nudgeOn }, set: { model.setNudges($0) }))
                .disabled(!model.nudgesAvailable || model.nudgeConnecting)
            if model.nudgeConnecting {
                LabeledContent("T3 Code", value: "Connecting…")
            } else if model.appSettings.nudgeOn, model.nudgeStatus.connected {
                LabeledContent("T3 Code", value: "Connected · \(model.nudgeStatus.access == "full-access" ? "Full access" : model.nudgeStatus.access ?? "unknown")")
            }
            if let error = model.nudgeStatus.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if !model.nudgesAvailable {
                Text("Off in test mode.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Nudges")
        } footer: {
            Text("When a T3 Code thread has made no progress for 30 minutes, including an idle parent whose summary identifies authorized unfinished work, Lighthouse sends it a short message asking it to continue, up to \(NudgePolicy.limit) times, 15 minutes apart. If it is still stuck, the thread shows as Needs you. Subagents, Claude Code and Codex app threads are never nudged. Turning this on connects to T3 Code on this Mac with Full access.")
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refreshNudgeStatus() }
    }
}

struct OpenInSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(OwningApp.allCases, id: \.self) { app in
                    LabeledContent(app.displayName) {
                        HStack {
                            let current = model.overrides[app]
                            Text(current?.appName ?? "\(TargetApp.forOwner(app).name) (default)")
                                .foregroundStyle(.secondary)
                            Button("Choose…") { choose(for: app) }
                            if current != nil { Button("Reset") { model.setOverride(nil, for: app) } }
                        }
                    }
                }
            } header: {
                Text("Open threads in")
            }
        }
        .formStyle(.grouped)
    }

    private func choose(for app: OwningApp) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setOverride(OpenOverride(appPath: url.path, appName: url.deletingPathExtension().lastPathComponent), for: app)
    }
}

struct ProjectsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Bindings") {
                if model.bindings.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(model.bindings, id: \.folder) { binding in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(binding.folder).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                            Text("→ \(binding.projectRoot)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Button("Remove") { model.removeBinding(binding.folder) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Usage (SPEC §6.6): enable each provider; credential status; retry.
struct UsageSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(Provider.allCases, id: \.self) { provider in
                Section {
                    Toggle("Show \(provider.displayName) usage", isOn: Binding(
                        get: { model.usageSettings.enabled.contains(provider) }, set: { model.setUsage(provider, enabled: $0) }))
                    if let reading = model.usage(for: provider) {
                        LabeledContent("Status", value: status(reading))
                        LabeledContent("Last success", value: reading.lastSuccessAt.map { "\(Age.short($0, now: Date())) ago" } ?? "None yet")
                        LabeledContent("Last attempt", value: reading.lastAttemptAt.map { "\(Age.short($0, now: Date())) ago" } ?? "Not yet")
                        Button("Retry now") { model.retryUsage(provider) }
                    }
                } header: {
                    Text(provider.displayName)
                } footer: {
                    Text(footer(provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func status(_ reading: ProviderUsage) -> String {
        switch reading.status {
        case .fresh: "Fresh"
        case .stale: "Stale"
        case .signInRequired: UsageWording.signIn(reading.provider)
        case .unavailable(let reason): reason
        }
    }

    private func footer(_ provider: Provider) -> String {
        switch provider {
        case .claude:
            "Uses your Claude Code sign-in."
        case .codex:
            "Uses your Codex sign-in."
        }
    }
}

/// Settings › Notifications (SPEC §8): opt-in, per-category switches, pause, Focus note.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var systemStatus = "Checking…"

    var body: some View {
        Form {
            Section {
                Toggle("Allow Lighthouse notifications", isOn: Binding(
                    get: { model.appSettings.notificationsOn }, set: { model.setNotifications($0) }))
                LabeledContent("macOS permission", value: systemStatus)
                Toggle("Pause alerts", isOn: Binding(get: { model.appSettings.alertsPaused }, set: { model.setAlertsPaused($0) }))
            }
            Section("Notify me about") {
                ForEach(NotificationCategory.allCases, id: \.self) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { model.appSettings.categories.contains(category) }, set: { model.setCategory(category, $0) }))
                }
                .disabled(!model.appSettings.notificationsOn)
            }
        }
        .formStyle(.grouped)
        .task(id: model.notifierStatusTick) {
            await model.notifier.refreshStatus()
            systemStatus = switch model.notifier.status {
            case .authorized, .provisional: "Allowed"
            case .denied: "Denied in System Settings"
            case .notDetermined: Notifier.available ? "Not asked yet" : "Unavailable"
            @unknown default: "Unknown"
            }
        }
    }
}

/// Settings › Summaries (M8, SPEC 2.9 §6.6): provider (Off / Claude / ChatGPT), model, call history,
/// what is sent, and recent activity (counts only).
struct SummarySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var modelText = ""

    private var settings: SummarySettings { model.summarySettings }

    var body: some View {
        Form {
            Section {
                Picker("Summarize threads with", selection: Binding(get: { settings.provider }, set: { provider in
                    var next = settings
                    next.provider = provider
                    model.setSummarySettings(next)
                })) {
                    Text("Off").tag(SummaryProvider.off)
                    Text("Claude").tag(SummaryProvider.claude)
                    Text("ChatGPT").tag(SummaryProvider.chatgpt)
                }
                .pickerStyle(.radioGroup)
                if settings.isOn {
                    LabeledContent("Model") {
                        HStack(spacing: 6) {
                            TextField("Model", text: $modelText, prompt: Text(SummarySettings.defaultModel(settings.provider) ?? ""))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .frame(width: 170)
                                .onSubmit(commitModel)
                            if modelText != SummarySettings.defaultModel(settings.provider) {
                                Button("Use default") {
                                    modelText = SummarySettings.defaultModel(settings.provider) ?? ""
                                    commitModel()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    if !SummarySettings.validModel(modelText) && !modelText.isEmpty {
                        Text("Letters, digits and . _ : / - only.").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    LabeledContent("CLI", value: model.summaryCLI(settings.provider)
                        ?? "Not found")
                }
                LabeledContent("Calls in the last hour", value: "\(model.summaryStatus.callsLastHour)")
                if let last = model.summaryStatus.last {
                    LabeledContent("Last result", value: Self.outcome(last))
                }
                Button("Delete stored summaries") { model.clearSummaries() }
                    .disabled(model.summaries.isEmpty)
            } header: {
                Text("Thread summaries")
            }
            Section("What is sent") {
                Text(Self.privacyNote(settings.provider))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { modelText = settings.model ?? "" }
        .onChange(of: settings.provider) { _, _ in modelText = settings.model ?? "" }
    }

    private func commitModel() {
        guard SummarySettings.validModel(modelText) else { return }
        var next = settings
        switch settings.provider {
        case .off: return
        case .claude: next.claudeModel = modelText
        case .chatgpt: next.chatgptModel = modelText
        }
        model.setSummarySettings(next)
    }

    static func privacyNote(_ provider: SummaryProvider) -> String {
        let what = "each active thread's title and last 24 KB of chat text, secrets removed. Only the summary is stored."
        switch provider {
        case .off: return "Nothing is sent."
        case .claude: return "Sends Anthropic " + what
        case .chatgpt: return "Sends OpenAI " + what
        }
    }

    static func outcome(_ outcome: SummaryService.Report.Outcome) -> String {
        switch outcome {
        case .made: "Summary made"
        case .unchanged: "No change"
        case .noTranscript: "No readable transcript"
        case .cliMissing: "CLI not found"
        case .scratchUnavailable: "Working folder unavailable"
        case .notLaunched: "CLI did not start"
        case .timedOut: "Stopped after 60 seconds"
        case .failed: "CLI error"
        case .emptyAnswer: "Empty answer"
        case .redactionOverBudget: "Skipped; nothing sent"
        }
    }
}
