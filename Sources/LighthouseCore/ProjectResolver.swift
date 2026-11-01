import Foundation

/// An explicit owner binding: any cwd at or below `folder` belongs to the project at `projectRoot`.
public struct ProjectBinding: Sendable, Hashable, Codable {
    public var folder: String
    public var projectRoot: String

    public init(folder: String, projectRoot: String) {
        self.folder = folder
        self.projectRoot = projectRoot
    }
}

/// Maps a session cwd to a stable project (SPEC §5), in order:
/// 1. explicit binding, 2. T3 project workspace root, 3. git common dir (worktrees join their
/// main repo), 4. the folder directly under a projects root (`~/Projects`). Anything else is
/// Unassigned. Projects are never merged by name; identity is the canonical root path.
///
/// Git metadata is read from `.git`, `gitdir:` and `commondir` files, which is what
/// `git rev-parse --git-common-dir` resolves, without spawning git per cwd.
public final class ProjectResolver {
    public let home: String
    public let projectsRoots: [String]
    public let bindings: [ProjectBinding]
    public let t3Roots: [String]
    /// T3 project titles by lower-cased standardized root; the project name for rule 2.
    public let t3Titles: [String: String]

    private let fm = FileManager.default
    private var cache: [String: ProjectIdentity] = [:]
    private var caseCache: [String: String] = [:]
    private var listingCache: [String: [String]] = [:]

    public init(home: String = NSHomeDirectory(), projectsRoots: [String]? = nil, bindings: [ProjectBinding] = [], t3Roots: [String] = [],
                t3Titles: [String: String] = [:]) {
        self.home = Self.standardize(home)
        self.projectsRoots = (projectsRoots ?? [(home as NSString).appendingPathComponent("Projects")]).map(Self.standardize)
        self.bindings = bindings.map { ProjectBinding(folder: Self.standardize($0.folder), projectRoot: Self.standardize($0.projectRoot)) }
        self.t3Roots = t3Roots.map(Self.standardize)
        self.t3Titles = Dictionary(t3Titles.map { (Self.standardize($0.key).lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    public static let unassignedRoot = "unassigned:"

    /// Resolves one cwd. Returns an Unassigned identity (root `unassigned:<cwd>`) when no rule matches.
    public func resolve(cwd rawCwd: String) -> ProjectIdentity {
        let cwd = Self.standardize(rawCwd)
        if let cached = cache[cwd] { return cached }
        let identity = match(cwd) ?? Self.unassigned(cwd)
        cache[cwd] = identity
        return identity
    }

    /// Resolves many sessions. A cwd that no longer exists (a removed worktree) joins the one known
    /// project whose `origin` remote matches the session's recorded repository URL.
    public func resolveAll(_ inputs: [(cwd: String, repositoryURL: String?)]) -> [ProjectIdentity] {
        var results = inputs.map { resolve(cwd: $0.cwd) }
        var byRemote: [String: Set<ProjectIdentity>] = [:]
        for identity in Set(results) where identity.kind == .git {
            if let remote = originURL(root: identity.root).map(Self.normalizeRemote) {
                byRemote[remote, default: []].insert(identity)
            }
        }
        for (index, input) in inputs.enumerated() where results[index].isUnassigned {
            guard let url = input.repositoryURL, !fm.fileExists(atPath: Self.standardize(input.cwd)) else { continue }
            if let matches = byRemote[Self.normalizeRemote(url)], matches.count == 1, let project = matches.first {
                results[index] = project
            }
        }
        return results
    }

    static func unassigned(_ cwd: String) -> ProjectIdentity {
        ProjectIdentity(root: unassignedRoot + cwd, name: (cwd as NSString).lastPathComponent, kind: .unassigned)
    }

    private func match(_ cwd: String) -> ProjectIdentity? {
        if let binding = bindings.filter({ Self.isWithin(cwd, $0.folder) }).max(by: { $0.folder.count < $1.folder.count }) {
            let root = canonicalCase(binding.projectRoot)
            return ProjectIdentity(root: root, name: (root as NSString).lastPathComponent, kind: .bound)
        }
        if let t3 = t3Roots.filter({ Self.isWithin(cwd, $0) }).max(by: { $0.count < $1.count }) {
            let root = canonicalCase(t3)
            let title = t3Titles[t3.lowercased()].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return ProjectIdentity(root: root, name: title ?? (root as NSString).lastPathComponent, kind: .t3)
        }
        if let gitRoot = gitMainRoot(for: cwd), gitRoot != home, gitRoot != "/" {
            let root = canonicalCase(gitRoot)
            return ProjectIdentity(root: root, name: (root as NSString).lastPathComponent, kind: .git)
        }
        for projectsRoot in projectsRoots where Self.isWithin(cwd, projectsRoot) && cwd.count > projectsRoot.count {
            let rest = cwd.dropFirst(projectsRoot.count).drop(while: { $0 == "/" })
            guard let first = rest.split(separator: "/").first else { continue }
            let root = canonicalCase((projectsRoot as NSString).appendingPathComponent(String(first)))
            return ProjectIdentity(root: root, name: (root as NSString).lastPathComponent, kind: .folder)
        }
        return nil
    }

    /// Walks up from `cwd` to the nearest `.git`. For a worktree (`.git` file with `gitdir:`), follows
    /// `commondir` back to the main repository and returns its working tree root.
    func gitMainRoot(for cwd: String) -> String? {
        var dir = cwd
        while true {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dir }
                return worktreeMainRoot(dotGitFile: dotGit, worktreeDir: dir) ?? dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    private func worktreeMainRoot(dotGitFile: String, worktreeDir: String) -> String? {
        guard let text = try? String(contentsOfFile: dotGitFile, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = (worktreeDir as NSString).appendingPathComponent(gitdir) }
        gitdir = Self.standardize(gitdir)
        var common = gitdir
        if let commondir = try? String(contentsOfFile: (gitdir as NSString).appendingPathComponent("commondir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !commondir.isEmpty {
            common = commondir.hasPrefix("/") ? commondir : (gitdir as NSString).appendingPathComponent(commondir)
        }
        common = Self.standardize(common)
        // The common dir of a normal repository is `<root>/.git`.
        guard (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
    }

    private func originURL(root: String) -> String? {
        guard let config = try? String(contentsOfFile: (root as NSString).appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            if inOrigin, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `git@github.com:a/b.git`, `https://github.com/a/b` and `ssh://git@github.com/a/b.git` compare equal.
    static func normalizeRemote(_ url: String) -> String {
        var value = url.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "ssh://", "git://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if let at = value.firstIndex(of: "@"), !value[..<at].contains("/") { value = String(value[value.index(after: at)...]) }
        value = value.replacingOccurrences(of: ":", with: "/")
        if value.hasSuffix(".git") { value.removeLast(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// APFS is case-insensitive; `~/projects/x` and `~/Projects/X` must be one project. Uses the
    /// on-disk spelling of every existing component.
    func canonicalCase(_ path: String) -> String {
        if let cached = caseCache[path] { return cached }
        var result = "/"
        for component in path.split(separator: "/").map(String.init) {
            func match(_ entries: [String]) -> String? {
                entries.first { $0 == component } ?? entries.first { $0.caseInsensitiveCompare(component) == .orderedSame }
            }
            // A name missing from the cached listing may be newer than it: list that folder again.
            let actual = match(listing(result)) ?? match(listing(result, refresh: true)) ?? component
            result = (result as NSString).appendingPathComponent(actual)
        }
        caseCache[path] = result
        return result
    }

    /// Entry names of a directory, listed once per resolver: every root shares its ancestors
    /// (`/`, `/Users`, the home folder, `~/Projects`), so listing them again for each root would
    /// repeat the same work.
    private func listing(_ directory: String, refresh: Bool = false) -> [String] {
        if !refresh, let cached = listingCache[directory] { return cached }
        let entries = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        listingCache[directory] = entries
        return entries
    }

    static func standardize(_ path: String) -> String {
        var value = (path as NSString).expandingTildeInPath
        value = (value as NSString).standardizingPath
        // /private/var and /var name one place; keep the shorter user-facing form.
        if value.hasPrefix("/private/") { value = String(value.dropFirst("/private".count)) }
        return value
    }

    static func isWithin(_ path: String, _ folder: String) -> Bool {
        let p = path.lowercased(), f = folder.lowercased()
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
}
