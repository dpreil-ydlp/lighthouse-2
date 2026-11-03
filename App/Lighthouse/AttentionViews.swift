import AppKit
import LighthouseCore
import SwiftUI

/// Attention strip (SPEC §6.2 item 3, 28 pt, hidden when empty): `◆ Needs you 2 · Gone quiet 1`.
/// Each count filters the shelf; a `Clear filter ×` chip undoes it. A filter, not an inbox.
struct AttentionStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.attentionCounts
        if !counts.isEmpty || model.attentionFilter != nil {
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(.orange).accessibilityHidden(true)
                ForEach(Array(AttentionBucket.allCases.filter { counts[$0] != nil }.enumerated()), id: \.element) { index, bucket in
                    if index > 0 { Text("·").foregroundStyle(.tertiary).accessibilityHidden(true) }
                    let selected = model.attentionFilter == bucket
                    Button {
                        model.attentionFilter = selected ? nil : bucket
                    } label: {
                        Text("\(bucket.title) \(counts[bucket] ?? 0)")
                            .fontWeight(selected ? .semibold : .regular)
                            .underline(selected)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(bucket == .needsYou ? Color.red : Color.orange)
                    .help("Filter")
                    .accessibilityLabel("\(bucket.title), \(counts[bucket] ?? 0)\(selected ? ", filter on" : "")")
                }
                Spacer(minLength: 4)
                if model.attentionFilter != nil {
                    Button { model.attentionFilter = nil } label: {
                        HStack(spacing: 3) {
                            Text("Clear filter")
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear filter")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .padding(.horizontal, Metrics.inset)
            .frame(height: 28)
        }
    }
}

/// First-run onboarding in the panel (SPEC §6.6): detects sources, explains the one Keychain
/// prompt, asks notification permission, offers the login item. Nothing here reads a source file:
/// detection is an existence check of each source location.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    private struct Source: Identifiable {
        var id: String { name }
        let name: String
        let path: String
        var found: Bool { FileManager.default.fileExists(atPath: path) }
    }

    private var sources: [Source] {
        let home = NSHomeDirectory()
        return [Source(name: "Claude Code sessions", path: home + "/.claude/projects"),
                Source(name: "Codex sessions", path: home + "/.codex/sessions"),
                Source(name: "T3 Code", path: home + "/.t3/userdata/statev2.sqlite")]
    }

    var body: some View {
        let _ = model.loginItemTick
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to \(AppIdentity.name)").font(.system(size: 15, weight: .semibold))
            Text("Read-only. Lighthouse never controls your agents.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sources) { source in
                    HStack(spacing: 6) {
                        Image(systemName: source.found ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(source.found ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                        Text(source.name)
                        Spacer()
                        Text(source.found ? "Found" : "Not found").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                }
            }
            Toggle("Notify me when agents need me", isOn: Binding(
                get: { model.appSettings.notificationsOn }, set: { model.setNotifications($0) }))
                .font(.system(size: 12))
            Toggle("Open Lighthouse at login", isOn: Binding(get: { LoginItem.isOn }, set: { model.setLoginItem($0) }))
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Summarize active threads", isOn: Binding(
                    get: { model.summarySettings.isOn }, set: { on in
                        var next = model.summarySettings
                        next.provider = on ? (next.provider == .off ? .claude : next.provider) : .off
                        model.setSummarySettings(next)
                    }))
                    .font(.system(size: 12))
                Text("Sends recent conversation text to \(model.summarySettings.provider == .chatgpt ? "OpenAI" : "Anthropic").")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(model.appSettings.hotkey.label) opens this panel."
                     + (model.appSettings.hotkey == .optionSpace && Hotkey.chatGPTInstalled ? " ChatGPT uses it too." : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { model.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(Metrics.inset)
    }
}
