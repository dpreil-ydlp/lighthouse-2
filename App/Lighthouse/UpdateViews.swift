import AppKit
import LighthouseCore
import Observation
import SwiftUI

/// Update checks and the one-click install (SPEC 2.12). Checks the public release list at launch
/// and every 6 hours (Settings › General can turn that off), or when asked. Installing downloads
/// the newest release, checks its SHA-256 and bundle, quits, swaps the app and opens the new copy.
@MainActor
@Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, installing
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var offer: UpdateOffer?
    private(set) var lastChecked: Date?
    let current: AppVersion?
    private(set) var auto: Bool

    private let updater: Updater
    private let logFile: URL
    private var schedule: Task<Void, Never>?

    static let interval: TimeInterval = 6 * 3600

    init(storeFolder: URL, testFeed: URL?, auto: Bool,
         version: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) {
        current = version.flatMap(AppVersion.init)
        self.auto = auto
        logFile = storeFolder.appendingPathComponent("update.log")
        let work = storeFolder.appendingPathComponent("updates", isDirectory: true)
        if let testFeed {
            updater = Updater(transport: GitHubTransport(allowFiles: true), feedURL: URL(fileURLWithPath: testFeed.path), workFolder: work, allowFileAssets: true)
            log.notice("update feed from test arguments")
        } else {
            updater = Updater(workFolder: work)
        }
        if auto { startSchedule() }
    }

    var available: Bool { offer != nil }
    var busy: Bool { phase == .checking || phase == .installing }

    func setAuto(_ on: Bool) {
        auto = on
        schedule?.cancel()
        schedule = nil
        if on { startSchedule() }
    }

    /// First check 20 s after launch (sources index first), then every 6 hours.
    private func startSchedule() {
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(UpdateController.interval))
            }
        }
    }

    /// Checks again when the panel opens and the last check is older than the interval (a Mac that
    /// slept through the timer).
    func panelOpened() {
        guard auto, !busy, let last = lastChecked, Date().timeIntervalSince(last) > Self.interval else { return }
        Task { await check() }
    }

    func check() async {
        guard !busy, let current else { return }
        phase = .checking
        do {
            offer = try await updater.check(current: current)
            lastChecked = Date()
            phase = offer == nil ? .upToDate : .available
            log.notice("update check current=\(current.description, privacy: .public) latest=\(self.offer?.latest.version.description ?? "none", privacy: .public) newer=\(self.offer?.releases.count ?? 0, privacy: .public)")
        } catch {
            lastChecked = Date()
            phase = offer == nil ? .failed("\(error)") : .available
            log.error("update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Downloads and verifies the newest release, starts the swap, and quits. On any failure the
    /// installed app is left as it was.
    func install(onFailure: @escaping (String) -> Void) {
        guard let release = offer?.latest, phase != .installing else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app", Updater.canReplace(target) else {
            let reason = UpdateFeed.Failure.notWritable(target.deletingLastPathComponent().path).description
            phase = .failed(reason)
            onFailure(reason)
            return
        }
        phase = .installing
        log.notice("update install version=\(release.version.description, privacy: .public)")
        let updater = self.updater
        Task { [weak self] in
            do {
                let staged = try await updater.stage(release)
                guard let self else { return }
                let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
                guard Updater.launchInstall(pid: ProcessInfo.processInfo.processIdentifier, staged: staged, target: target,
                                            logFile: self.logFile, arguments: arguments) else {
                    throw UpdateFeed.Failure.notWritable(target.path)
                }
                log.notice("update staged; quitting for the swap")
                NSApp.terminate(nil)
            } catch {
                let reason = "\(error)"
                log.error("update install failed: \(reason, privacy: .public)")
                // Keep the button so the owner can try again; the toast says what went wrong.
                self?.phase = self?.offer != nil ? .available : .failed(reason)
                onFailure("Update failed: \(reason)")
            }
        }
    }
}

/// Header pill shown when a newer release exists. Hover lists every change between this copy and
/// the newest release; a click installs it and restarts Lighthouse.
struct UpdateButton: View {
    @Environment(AppModel.self) private var model
    @State private var overButton = false
    @State private var overNotes = false
    @State private var showNotes = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let updates: UpdateController = model.updates
        if let offer = updates.offer {
            Button { model.installUpdate() } label: {
                HStack(spacing: 4) {
                    if updates.phase == .installing {
                        ProgressView().controlSize(.mini)
                        Text("Updating…")
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(updates.phase == .installing)
            .fixedSize()
            .accessibilityLabel("Update to \(AppIdentity.name) \(offer.latest.version.description)")
            .accessibilityHint(UpdateNotesText.plain(offer))
            .onHover { overButton = $0; hoverChanged() }
            .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                UpdateNotesView(offer: offer)
                    .onHover { overNotes = $0; hoverChanged() }
            }
        }
    }

    /// Opens after a short rest on the button; stays open while the pointer is on the button or
    /// the notes, so a long list can be scrolled.
    private func hoverChanged() {
        hoverTask?.cancel()
        let wanted = overButton || overNotes
        guard wanted != showNotes else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 250 : 300))
            guard !Task.isCancelled else { return }
            showNotes = overButton || overNotes
        }
    }
}

/// The change list in the hover: newest release first, each with its headline and bullets.
struct UpdateNotesView: View {
    let offer: UpdateOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(AppIdentity.name) \(offer.latest.version.description) is available")
                    .font(.system(size: 13, weight: .semibold))
                Text("You have \(offer.current.description). Click Update to install and restart.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(offer.releases, id: \.tag) { release in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(release.version.description).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                if let date = release.publishedAt {
                                    Text(date, format: .dateTime.month(.abbreviated).day()).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                            }
                            if let headline = release.notes.headline {
                                Text(UpdateNotesText.inline(headline)).font(.system(size: 12))
                            }
                            ForEach(Array(release.notes.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(UpdateNotesText.inline(item))
                                }
                                .font(.system(size: 12))
                            }
                            if release.notes.headline == nil && release.notes.items.isEmpty {
                                Text("No notes for this release.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }
}

enum UpdateNotesText {
    /// Release notes are Markdown: bold and code render, links stay text.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// For VoiceOver: the same list as one string.
    static func plain(_ offer: UpdateOffer) -> String {
        offer.releases.map { release in
            ([release.version.description, release.notes.headline].compactMap { $0 } + release.notes.items)
                .map { sentence(String(inline($0).characters)) }.joined(separator: " ")
        }.joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return [".", "!", "?", ":"].contains(where: trimmed.hasSuffix) ? trimmed : trimmed + "."
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates: UpdateController = model.updates
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.auto }, set: { model.setUpdatesAuto($0) }))
            HStack {
                Text(status(updates)).foregroundStyle(statusIsProblem(updates) ? Color.orange : Color.secondary)
                Spacer()
                if updates.offer != nil {
                    Button(updates.phase == .installing ? "Updating…" : "Update to \(updates.offer!.latest.version.description)") { model.installUpdate() }
                        .disabled(updates.busy)
                } else {
                    Button(updates.phase == .checking ? "Checking…" : "Check now") { Task { await updates.check() } }
                        .disabled(updates.busy)
                }
            }
            Text("Asks GitHub for the public Lighthouse 2 release list. An update is downloaded only when you click Update; its SHA-256 is checked before it replaces this copy.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func status(_ updates: UpdateController) -> String {
        let version = updates.current?.description ?? "unknown"
        let checked = updates.lastChecked.map { " · checked \(Age.short($0, now: Date())) ago" } ?? ""
        switch updates.phase {
        case .idle: return "Version \(version)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "\(version) is the newest version\(checked)"
        case .available, .installing: return "\(updates.offer?.latest.version.description ?? "") is available (you have \(version))"
        case .failed(let reason): return "Could not check: \(reason)"
        }
    }

    private func statusIsProblem(_ updates: UpdateController) -> Bool {
        if case .failed = updates.phase { return true }
        return false
    }
}
