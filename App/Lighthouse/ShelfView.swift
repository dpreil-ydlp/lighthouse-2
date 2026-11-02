import LighthouseCore
import SwiftUI

/// The stable project shelf (SPEC §6.2 item 5).
struct ShelfView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shelf = model.shelf
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoading && shelf.isEmpty {
                ForEach(0..<4, id: \.self) { _ in PlaceholderRow() }
            } else if shelf.isEmpty {
                // Quiet may be hidden: projects can exist with none on the shelf.
                Text(model.hasProjects ? "No recent activity" : "No projects yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(Metrics.inset)
            }
            ForEach(ShelfGroup.allCases, id: \.self) { group in
                let rows = shelf[group]
                if !rows.isEmpty { GroupSection(group: group, rows: rows) }
            }
        }
        .padding(.bottom, 6)
    }
}

struct GroupSection: View {
    @Environment(AppModel.self) private var model
    let group: ShelfGroup
    let rows: [ProjectSummary]

    private var alwaysOpen: Bool { group.alwaysOpen }
    private var isOpen: Bool { alwaysOpen || model.expandedGroups.contains(group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                let visible = group == .pinned && !model.pinsExpanded ? Array(rows.prefix(ShelfBuilder.pinsVisible)) : rows
                ForEach(visible) { project in ProjectRow(project: project) }
                if group == .pinned && rows.count > ShelfBuilder.pinsVisible && !model.pinsExpanded {
                    Button("More pins · \(rows.count - ShelfBuilder.pinsVisible)") { model.showMorePins() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Metrics.inset + 22)
                        .padding(.vertical, 4)
                        .background(model.focused == .morePins ? Color.accentColor.opacity(0.12) : .clear)
                        .id(FocusOrder.Stop.morePins)
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        let stop = FocusOrder.Stop.groupHeader(group)
        let focused = model.focused == stop
        if alwaysOpen {
            Text("\(group.title.uppercased()) · \(rows.count)")
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 12).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(focused ? Color.accentColor.opacity(0.12) : .clear)
                .id(stop)
        } else {
            Button {
                if model.expandedGroups.remove(group) == nil { model.expandedGroups.insert(group) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14)
                    Text("\(group.title) · \(rows.count)").font(.system(size: 13))
                    Spacer()
                    if !isOpen {
                        Text(rows.prefix(3).map(\.identity.name).joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 6)
            .background(focused ? Color.accentColor.opacity(0.12) : .clear)
            .id(stop)
            .accessibilityLabel("\(group.title), \(rows.count) projects, \(isOpen ? "expanded" : "collapsed")")
        }
    }
}

struct PlaceholderRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 140, height: 11)
            RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.6)).frame(width: 210, height: 9)
        }
        .padding(.horizontal, Metrics.inset + 22)
        .frame(height: 46, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// Two-line project row with in-place expansion (SPEC §6.2).
struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: ProjectSummary
    @State private var hovering = false

    private var root: String { project.identity.root }
    private var expanded: Bool { model.expandedProject == root }
    private var pinned: Bool { model.prefs.pinned.contains(root) }
    private var headline: ProjectHeadline? {
        ProjectHeadline.make(for: project, recentlyCompleted: model.shelf.group(of: root) == .recentlyCompleted) { model.summary(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded { expansion }
        }
    }

    private var row: some View {
        let stop = FocusOrder.Stop.project(root)
        let primary = model.router.primaryTarget(for: project)
        return HStack(alignment: .top, spacing: 8) {
            Button { toggle() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(expanded ? "Collapse \(project.identity.name)" : "Expand \(project.identity.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button { model.route = .project(root) } label: {
                        Text(project.identity.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(project.identity.folderPath)
                    ForEach(project.owningApps, id: \.self) { SourceChip(app: $0) }
                    if let tag = ShelfBuilder.ownerTag(for: project, prefs: model.prefs), project.status == .needsYou {
                        Text(tag).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if hovering || model.focused == stop {
                        Button(primary.action.label) { model.perform(primary.action) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .help(primary.thread.map { "\(primary.action.label): \($0.displayTitle)" } ?? primary.action.label)
                        Button { model.togglePin(root) } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .help(pinned ? "Unpin" : "Pin")
                            .disabled(project.identity.isUnassigned)
                    } else {
                        if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        if let last = project.lastActivityAt {
                            Text(Age.short(last, now: model.now)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                StatusLine(project: project)
                if let headline { HeadlineLine(headline: headline) }
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(model.focused == stop || expanded ? Color.primary.opacity(0.06) : .clear).padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .id(stop)
        .contextMenu { ProjectMenu(project: project) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(project.identity.name), \(project.attention.first ?? StatusLine.text(for: project, now: model.now))\(headline.map { ", \($0.isSummary ? "AI summary" : "latest thread"): \($0.text)" } ?? "")")
    }

    private func toggle() {
        model.expandedProject = expanded ? nil : root
    }

    @ViewBuilder private var expansion: some View {
        let live = project.liveThreads
        VStack(alignment: .leading, spacing: 0) {
            ForEach(live.prefix(ShelfBuilder.threadsShownExpanded)) { thread in
                ThreadRow(thread: thread, projectRoot: root, compact: true)
            }
            let hidden = project.threads.count - min(live.count, ShelfBuilder.threadsShownExpanded)
            if hidden > 0 {
                let stop = FocusOrder.Stop.showAll(project: root)
                Button {
                    model.route = .project(root)
                } label: {
                    HStack(spacing: 4) {
                        if live.count > ShelfBuilder.threadsShownExpanded {
                            Text("Show all \(project.threads.count) threads")
                        } else {
                            Text("\(project.stoppedThreads.count) stopped")
                        }
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, Metrics.inset + 40)
                .padding(.vertical, 5)
                .background(model.focused == stop ? Color.accentColor.opacity(0.12) : .clear)
                .id(stop)
            }
        }
        .padding(.bottom, 4)
    }
}

struct SourceChip: View {
    let app: OwningApp
    var body: some View {
        Text(app.chipLabel)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }
}

/// Line 2 of a project row: attention reason in amber, else the status (SPEC §6.2, §5.3 wording).
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    let project: ProjectSummary

    var body: some View {
        if let reason = project.attention.first {
            Label(reason, systemImage: "diamond.fill")
                .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
        } else {
            Text(Self.text(for: project, now: model.now))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }
    }

    static func text(for project: ProjectSummary, now: Date) -> String {
        let count = project.threads.count
        let threads = "\(count) thread\(count == 1 ? "" : "s")"
        let age = project.lastActivityAt.map { Age.short($0, now: now) } ?? "—"
        switch project.status {
        case .needsYou: return "Needs you · \(threads)"
        case .working:
            let running = project.runningThreadCount
            return "Working · \(running) running · \(threads)"
        case .recent: return "Recent activity · \(age) ago · \(threads)"
        case .quiet, .dormant: return "No activity for \(age) · \(threads)"
        }
    }
}

/// Line 3 of an active project row (M10): what the main thread is doing, at a glance.
struct HeadlineLine: View {
    let headline: ProjectHeadline

    var body: some View {
        Text(headline.text)
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.8))
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .help(headline.isSummary ? "AI summary" : "Latest thread")
            .accessibilityHidden(true)
    }
}

struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let project: ProjectSummary

    var body: some View {
        let root = project.identity.root
        let pinned = model.prefs.pinned.contains(root)
        if !project.identity.isUnassigned {
            Button(pinned ? "Unpin" : "Pin") { model.togglePin(root) }
        }
        Divider()
        ForEach(Array(model.router.allTargets(for: project).enumerated()), id: \.offset) { _, entry in
            Button("\(entry.action.label) — \(entry.thread.displayTitle)") { model.perform(entry.action) }
        }
        Button("Reveal in Finder") { model.reveal(project.identity.folderPath) }
        Button("Open project page") { model.route = .project(root) }
        Divider()
        if !project.identity.isUnassigned {
            Button(model.prefs.paused.contains(root) ? "Unpause" : "Pause") { model.togglePaused(root) }
            Button(model.prefs.archived.contains(root) ? "Unarchive" : "Archive") { model.toggleArchived(root) }
        }
        Button(project.identity.isUnassigned ? "Bind to project…" : "Bind folder…") { model.chooseBinding(for: project) }
    }
}

struct SearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hits = model.searchHits
        LazyVStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                Text("No matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(Metrics.inset)
            }
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                Button {
                    model.route = .project(hit.project.identity.root)
                    if let thread = hit.thread { model.expandedThreads.insert(thread.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.thread?.displayTitle ?? hit.project.identity.name).font(.system(size: 13)).lineLimit(1)
                        Text(hit.breadcrumb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.inset)
                .padding(.vertical, 5)
                .background(model.searchFocus == index ? Color.accentColor.opacity(0.12) : .clear)
                .id("hit-\(index)")
            }
        }
    }
}
