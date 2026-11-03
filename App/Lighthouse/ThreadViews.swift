import LighthouseCore
import SwiftUI

/// Thread row with Level 3 inline expansion (SPEC §6.5).
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: SessionThread
    let projectRoot: String
    /// Compact rows sit under a shelf project; full rows sit on the project page.
    var compact = false
    /// The thread waits for the owner: a "Needs you" tag that opens the thread.
    var waiting = false

    private var expanded: Bool { model.expandedThreads.contains(thread.id) }
    private var summary: ThreadSummary? { model.summary(for: thread) }
    private var focused: Bool {
        compact ? model.focused == .thread(project: projectRoot, thread: thread.id) : model.page.focused == .thread(thread.id)
    }

    private func toggle() {
        if model.expandedThreads.remove(thread.id) == nil { model.expandedThreads.insert(thread.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The tag is its own button beside the row's toggle buttons (a button inside a button
            // does not get the click on macOS).
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        if compact {
                            StateDot(state: thread.state)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(width: 10)
                                .foregroundStyle(.secondary)
                        }
                        Text(thread.displayTitle)
                            .font(.system(size: compact ? 12.5 : 13))
                            .foregroundStyle(thread.state == .stopped ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(thread.displayTitle), \(thread.owningApp.displayName), \(StateText.label(thread.state)), \(Age.short(thread.latestActivityAt, now: model.now)) ago"
                                    + (waiting ? ", needs you" : "") + (summary.map { ", AI summary: \($0.line1)" } ?? ""))
                if waiting {
                    NeedsYouTag(help: "Open in \(thread.owningApp.displayName)") { model.openWaiting(thread) }
                }
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Text("\(thread.owningApp.chipLabel) · \(StateText.label(thread.state)) · \(Age.short(thread.latestActivityAt, now: model.now))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        if compact {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityHidden(true)
            }
            .padding(.leading, compact ? Metrics.inset + 30 : Metrics.inset)
            .padding(.trailing, Metrics.inset)
            .padding(.top, 5)
            .padding(.bottom, summary == nil ? 5 : 1)
            .background(focused ? Color.accentColor.opacity(0.12) : .clear)
            .id(compact ? AnyHashable(FocusOrder.Stop.thread(project: projectRoot, thread: thread.id)) : AnyHashable(PageNavigation.Stop.thread(thread.id)))

            if let summary, !expanded {
                SummaryLine(summary: summary)
                    .padding(.leading, compact ? Metrics.inset + 30 + 22 : Metrics.inset + 18)
                    .padding(.trailing, Metrics.inset)
                    .padding(.bottom, 5)
                    .accessibilityHidden(true)
            }

            if expanded {
                ThreadDetail(thread: thread)
                    .padding(.leading, compact ? Metrics.inset + 30 : Metrics.inset + 18)
                    .padding(.trailing, Metrics.inset)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// The one-line AI summary under a thread title (M8), with the maker and age in its tooltip.
struct SummaryLine: View {
    @Environment(AppModel.self) private var model
    let summary: ThreadSummary

    var body: some View {
        Text(summary.line1).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        .help("AI summary · \(SummaryWording.maker(summary)) · \(Age.short(summary.madeAt, now: model.now)) ago")
    }
}

enum SummaryWording {
    static func maker(_ summary: ThreadSummary) -> String {
        "\(summary.provider.displayName) \(SummarySettings.modelLabel(summary.model))"
    }
}

struct StateDot: View {
    let state: ThreadState
    var body: some View {
        Group {
            switch state {
            case .running: Circle().fill(.green)
            case .waitingForOwner: Circle().fill(.orange)
            case .idle: Circle().strokeBorder(.secondary, lineWidth: 1.2)
            case .unknown: Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
            case .stopped: Circle().fill(.quaternary)
            }
        }
        .frame(width: 7, height: 7)
        .frame(width: 14)
        .accessibilityHidden(true)
    }
}

enum StateText {
    static func label(_ state: ThreadState) -> String {
        switch state {
        case .running: "running"
        case .waitingForOwner: "waiting for you"
        case .idle: "idle"
        case .stopped: "stopped"
        case .unknown: "unknown"
        }
    }
}

/// Level 3 detail: title, owning app, state, times, tokens, Open action, subagent tree.
struct ThreadDetail: View {
    @Environment(AppModel.self) private var model
    let thread: SessionThread

    var body: some View {
        let action = model.router.target(for: thread)
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.displayTitle).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let summary = model.summary(for: thread) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.line1).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if let line2 = summary.line2 {
                        Text(line2).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("AI summary · \(SummaryWording.maker(summary)) · \(Age.short(summary.madeAt, now: model.now)) ago")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AI summary by \(SummaryWording.maker(summary)): \(summary.line1)\(summary.line2.map { ". \($0)" } ?? "")")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                field("Opens in", "\(TargetApp.forOwner(thread.owningApp).name) · \(thread.owningApp.displayName) thread")
                field("State", StateText.label(thread.state).capitalized)
                if let request = thread.pendingRequest, thread.state == .waitingForOwner {
                    field("Waiting", request.label)
                }
                field("Last activity", Age.stamp(thread.lastActivityAt, now: model.now))
                field("Last progress", thread.lastProgressAt.map { Age.stamp($0, now: model.now) } ?? "Not observed")
                field("Source read", "\(Age.short(thread.sourceReadAt, now: model.now)) ago")
                if let tokens = thread.tokensTotal, let provider = thread.primaryProvider {
                    let (span, _) = LocalTokenAttribution.window(for: model.usage(for: provider), now: model.now)
                    let window = LocalTokenAttribution.tokens(thread, provider: provider, in: span)
                    field("Local tokens", TokenWording.threadDetail(window: window, session: tokens,
                                                                   partial: LocalTokenAttribution.partial(thread, provider: provider)))
                }
                if let stall = model.openStall(forThread: thread.id) {
                    field("Stall check", "No progress for \(Age.short(stall.enteredAt.addingTimeInterval(-AttentionRules.silenceAfter), now: model.now)) ⚠")
                } else if let note = AttentionRules.stallNote(for: thread) {
                    field("Stall check", note)
                }
            }
            .font(.system(size: 11))
            HStack(spacing: 8) {
                Button(action.label) { model.perform(action) }
                    .controlSize(.small)
                if let stall = model.openStall(forThread: thread.id) {
                    Button("Acknowledge") { model.acknowledge(stall) }
                        .controlSize(.small)
                        .help("Dismiss")
                }
                if let id = action.sessionId {
                    Button("Copy session ID") { model.copySessionId(id) }
                        .controlSize(.small)
                        .help(id)
                }
                Button { model.reveal(thread.cwd) } label: { Image(systemName: "folder") }
                    .controlSize(.small)
                    .help("Reveal \(thread.cwd) in Finder")
                    .accessibilityLabel("Reveal folder in Finder")
            }
            .padding(.top, 2)
            if !thread.subagents.isEmpty {
                SubagentTree(thread: thread)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(2)
        }
    }
}

struct SubagentTree: View {
    @Environment(AppModel.self) private var model
    let thread: SessionThread
    @State private var showAll = false

    private var subagents: [Subagent] { thread.subagents }

    var body: some View {
        let silent = Set(thread.subagents.map(\.id).filter { model.openItem(forSubagent: $0) != nil })
        VStack(alignment: .leading, spacing: 3) {
            Text("SUBAGENTS · \(subagents.count)").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
                .padding(.top, 4)
            let shown = showAll ? subagents : Array(subagents.prefix(5))
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, sub in
                HStack(spacing: 6) {
                    Text(index == shown.count - 1 ? "└" : "├").foregroundStyle(.tertiary)
                    Text(sub.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if silent.contains(sub.id) {
                        // SPEC §6.5: `test-runner · Claude · silent 31 m ⚠`, with a local Acknowledge.
                        Text("\(sub.provider.displayName) · silent \(Age.short(sub.lastActivityAt, now: model.now)) ⚠")
                            .foregroundStyle(.orange).monospacedDigit()
                        if let item = model.openItem(forSubagent: sub.id) {
                            Button("Acknowledge") { model.acknowledge(item) }
                                .buttonStyle(.borderless).controlSize(.mini)
                                .help("Dismiss")
                        }
                    } else {
                        Text("\(sub.provider.displayName) · \(StateText.label(sub.state)) · \(Age.short(sub.lastActivityAt, now: model.now))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .accessibilityElement(children: .combine)
            }
            if subagents.count > 5 && !showAll {
                Button("Show all \(subagents.count) subagents") { showAll = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Level 2 project page (SPEC §6.4).
struct ProjectPage: View {
    @Environment(AppModel.self) private var model
    let root: String
    private var showEarlier: Bool { model.page.showEarlier }
    /// Receipt renders draw the thread list without its scroll view (ImageRenderer leaves
    /// AppKit-backed scroll views blank).
    @Environment(\.receiptFlat) private var flat

    var body: some View {
        if let project = model.project(root) {
            content(project)
                .onAppear { model.resolveLaunchExpansion(for: project) }
        } else {
            VStack(spacing: 8) {
                header(title: "Project", action: nil)
                Text("Project no longer observed").font(.system(size: 12)).foregroundStyle(.secondary).padding()
            }
        }
    }

    private func header(title: String, action: (OpenAction, SessionThread?)?) -> some View {
        HStack(spacing: 8) {
            Button { model.pop() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back")
                }
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Spacer()
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let (action, thread) = action {
                Button(action.label) { model.perform(action) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .help(thread.map { "\(action.label): “\($0.displayTitle)”" } ?? action.label)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: 38)
    }

    private func content(_ project: ProjectSummary) -> some View {
        let primary = model.router.primaryTarget(for: project)
        let (current, earlier) = ThreadDisplay.split(project.threads, now: model.now)
        return VStack(alignment: .leading, spacing: 0) {
            header(title: project.identity.name, action: (primary.action, primary.thread))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StateDot(state: project.status == .needsYou ? .waitingForOwner : project.status == .working ? .running : .idle)
                    Text(StatusLine.text(for: project, now: model.now)).font(.system(size: 12))
                }
                if let thread = primary.thread {
                    Text("Open targets “\(thread.displayTitle)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(project.attention, id: \.self) { reason in
                    Label(reason, systemImage: "diamond.fill").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, 8)
            Divider().opacity(0.5)
            if flat {
                threadList(project, current: current, earlier: earlier)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { threadList(project, current: current, earlier: earlier) }
                        .panelScroll(model)
                        .onChange(of: model.page.focused) { _, stop in
                            if let stop { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(AnyHashable(stop), anchor: nil) } }
                        }
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Button("Reveal in Finder") { model.reveal(project.identity.folderPath) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Text(project.identity.folderPath).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, Metrics.inset)
            .frame(height: 28)
        }
    }

    private func threadList(_ project: ProjectSummary, current: [SessionThread], earlier: [SessionThread]) -> some View {
        let waiting = Set(project.waitingThreads.map(\.id))
        return LazyVStack(alignment: .leading, spacing: 0) {
            Text("THREADS · \(project.threads.count)").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
                .padding(.horizontal, Metrics.inset).padding(.top, 10).padding(.bottom, 4)
            ForEach(current) { ThreadRow(thread: $0, projectRoot: project.identity.root, waiting: waiting.contains($0.id)) }
            if !earlier.isEmpty {
                Button { model.page.showEarlier.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showEarlier ? 90 : 0))
                        Text("\(earlier.count) earlier threads")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.inset).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.page.focused == .earlier ? Color.accentColor.opacity(0.12) : .clear)
                .id(AnyHashable(PageNavigation.Stop.earlier))
                if showEarlier { ForEach(earlier) { ThreadRow(thread: $0, projectRoot: project.identity.root, waiting: waiting.contains($0.id)) } }
            }
        }
        .padding(.bottom, 6)
    }
}

private struct ReceiptFlatKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var receiptFlat: Bool {
        get { self[ReceiptFlatKey.self] }
        set { self[ReceiptFlatKey.self] = newValue }
    }
}
