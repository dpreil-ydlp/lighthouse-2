import Foundation

/// Persistence for summaries (M8 A2): summary text, input hash and metadata, call times for the
/// usage display, and the user's settings. Never the request or any conversation text.
public protocol SummaryStoring: Sendable {
    func loadSummaries() -> [String: ThreadSummary]
    func saveSummary(_ summary: ThreadSummary)
    func deleteSummaries()
    func loadSummaryCalls(since: Date) -> [Date]
    func recordSummaryCall(at: Date, pruneBefore: Date)
}

/// Where the transcript tail comes from. The live source reads files read-only; tests and the
/// idle probe inject their own.
public protocol TranscriptSource: Sendable {
    /// The conversation text behind a thread, oldest first, before redaction (the service redacts
    /// it within its budget and cuts it to the tail); nil when nothing readable remains.
    func tail(paths: [String]) -> String?
}

public struct FileTranscriptSource: TranscriptSource {
    public let access: SourceAccess
    public init(access: SourceAccess = ReadOnlyFileSystem()) { self.access = access }
    public func tail(paths: [String]) -> String? { TranscriptTail.gather(paths: paths, access: access) }
}

/// Runs at most one summary call at a time, each with a 60 s timeout
/// (contract M8 Limits). With summaries off it returns at once: nothing is read, nothing starts.
public actor SummaryService {
    /// Result of one scheduling step. Metadata only: no request, transcript or CLI output.
    public struct Report: Sendable, Hashable {
        public enum Outcome: String, Sendable {
            /// A new summary was stored.
            case made
            /// The request equals the one behind the stored summary; no call was made.
            case unchanged
            case noTranscript
            case cliMissing
            case scratchUnavailable
            case notLaunched
            case timedOut
            case failed
            case emptyAnswer
            /// Redaction ran past `redactionBudget`: nothing was sent (or, for the answer, stored).
            case redactionOverBudget
        }

        public var threadId: String
        public var outcome: Outcome
        public var provider: SummaryProvider
        public var model: String
        /// True when a CLI process was started.
        public var called: Bool
        public var seconds: Double
        public var exitCode: Int32?
        public var requestBytes: Int
        public var stdoutBytes: Int
        public var stderrBytes: Int
    }

    public private(set) var settings: SummarySettings
    private let store: SummaryStoring?
    private let transcripts: TranscriptSource
    private let launcher: SummaryProcessLauncher
    private let locator: CLILocator
    private let scratch: String
    private let home: String
    private let timeout: TimeInterval
    /// Time allowed to redact one request (tail, title, project) and, separately, one answer.
    private let redactionBudget: TimeInterval
    private var summaries: [String: ThreadSummary]
    private var calls: [Date]
    private var failures: [String: SummaryFailure] = [:]
    private var busy = false
    public private(set) var lastReport: Report?
    /// Process starts by this service (tests and probes).
    public private(set) var launches = 0

    public init(settings: SummarySettings, store: SummaryStoring?, transcripts: TranscriptSource = FileTranscriptSource(),
                launcher: SummaryProcessLauncher = SystemProcessLauncher(), locator: CLILocator = CLILocator(),
                scratch: String, home: String = NSHomeDirectory(), timeout: TimeInterval = SummaryRules.callTimeout,
                redactionBudget: TimeInterval = Redactor.budget, now: Date = Date()) {
        self.settings = settings
        self.store = store
        self.transcripts = transcripts
        self.launcher = launcher
        self.locator = locator
        self.scratch = scratch
        self.home = home
        self.timeout = timeout
        self.redactionBudget = redactionBudget
        self.summaries = store?.loadSummaries() ?? [:]
        self.calls = store?.loadSummaryCalls(since: now.addingTimeInterval(-SummaryRules.callHistoryWindow)) ?? []
    }

    /// The default scratch folder: empty, owned by Lighthouse, outside every source folder.
    public static var defaultScratch: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.lighthouse.v2/summary-scratch", isDirectory: true).path
    }

    public func apply(_ settings: SummarySettings) {
        self.settings = settings
        failures.removeAll()
    }

    /// Stored summaries by thread id.
    public func all() -> [String: ThreadSummary] { summaries }

    public func callsInLastHour(now: Date = Date()) -> Int { SummaryRules.callsInWindow(calls, now: now) }

    public var isBusy: Bool { busy }

    public func clear() {
        summaries.removeAll()
        failures.removeAll()
        store?.deleteSummaries()
    }

    /// Picks the next due thread and summarizes it. Returns nil when nothing was attempted: off,
    /// busy (single flight), or no thread due.
    public func step(_ candidates: [SummaryCandidate], now: Date = Date()) async -> Report? {
        guard settings.isOn, let model = settings.model, !busy else { return nil }
        calls.removeAll { now.timeIntervalSince($0) >= SummaryRules.callHistoryWindow }
        guard let candidate = SummaryRules.next(candidates, summaries: summaries, failures: failures, now: now) else { return nil }
        busy = true
        defer { busy = false }
        let provider = settings.provider
        var report = Report(threadId: candidate.threadId, outcome: .failed, provider: provider, model: model, called: false,
                            seconds: 0, exitCode: nil, requestBytes: 0, stdoutBytes: 0, stderrBytes: 0)
        func finish(_ outcome: Report.Outcome) -> Report {
            report.outcome = outcome
            if outcome != .made && outcome != .unchanged {
                failures[candidate.threadId] = SummaryFailure(activityAt: candidate.lastActivityAt, at: now)
            }
            lastReport = report
            return report
        }

        guard let raw = transcripts.tail(paths: candidate.transcriptPaths) else { return finish(.noTranscript) }
        // Everything sent is redacted within one budget; past it, nothing is sent (M8-E03).
        let deadline = Date().addingTimeInterval(redactionBudget)
        guard let tail = TranscriptTail.finish(raw, deadline: deadline),
              let title = Redactor.redact(candidate.title, deadline: deadline),
              let project = Redactor.redact(candidate.projectName, deadline: deadline) else { return finish(.redactionOverBudget) }
        var redacted = candidate
        redacted.title = title
        redacted.projectName = project
        let request = SummaryRequest(candidate: redacted, tail: tail, provider: provider, model: model)
        report.requestBytes = request.prompt.utf8.count
        if var last = summaries[candidate.threadId], last.inputHash == request.inputHash {
            // Same request as last time (activity without new text): keep the summary, no call.
            last.activityAt = candidate.lastActivityAt
            summaries[candidate.threadId] = last
            store?.saveSummary(last)
            if last.continueWork == nil {
                failures[candidate.threadId] = SummaryFailure(activityAt: candidate.lastActivityAt, at: now)
            }
            return finish(.unchanged)
        }
        guard let executable = locator.locate(provider) else { return finish(.cliMissing) }
        guard prepareScratch() else { return finish(.scratchUnavailable) }
        guard let command = SummaryCLI.command(provider: provider, model: model, executable: executable, scratch: scratch, home: home) else {
            return finish(.failed)
        }
        calls.append(now)
        store?.recordSummaryCall(at: now, pruneBefore: now.addingTimeInterval(-SummaryRules.callHistoryWindow))
        launches += 1
        let outcome = await launcher.run(command, input: Data(request.prompt.utf8), timeout: timeout)
        report.called = outcome.launched
        report.seconds = outcome.seconds
        report.exitCode = outcome.exitCode
        report.stdoutBytes = outcome.stdout.count
        report.stderrBytes = outcome.stderrBytes
        guard outcome.launched else { return finish(.notLaunched) }
        guard !outcome.timedOut else { return finish(.timedOut) }
        guard outcome.exitCode == 0, let answer = SummaryCLI.answer(provider: provider, stdout: outcome.stdout) else { return finish(.failed) }
        guard let cleanAnswer = Redactor.redact(answer, deadline: Date().addingTimeInterval(redactionBudget)) else {
            return finish(.redactionOverBudget)
        }
        guard let (line1, line2) = SummaryText.lines(from: cleanAnswer) else { return finish(.emptyAnswer) }
        let summary = ThreadSummary(threadId: candidate.threadId, line1: line1, line2: line2, madeAt: now,
                                    activityAt: candidate.lastActivityAt, inputHash: request.inputHash, provider: provider, model: model,
                                    needsOwner: SummaryText.needsOwner(from: cleanAnswer) ?? false,
                                    continueWork: SummaryText.continueWork(from: cleanAnswer))
        summaries[candidate.threadId] = summary
        // Keep an incomplete judgment unknown, and use the existing backoff between cache checks.
        failures[candidate.threadId] = summary.continueWork == nil
            ? SummaryFailure(activityAt: candidate.lastActivityAt, at: now) : nil
        store?.saveSummary(summary)
        return finish(.made)
    }

    /// The working folder must exist and be empty, so a CLI finds no project files, instructions or
    /// settings there. Lighthouse never deletes anything in it: a non-empty folder fails closed.
    private func prepareScratch() -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: scratch, isDirectory: &isDirectory) {
            guard (try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)) != nil else { return false }
            return true
        }
        guard isDirectory.boolValue, let entries = try? fm.contentsOfDirectory(atPath: scratch) else { return false }
        return entries.isEmpty
    }

    /// Test and probe hook: marks threads as summarized at their current activity.
    func seed(_ summary: ThreadSummary) { summaries[summary.threadId] = summary }
}
