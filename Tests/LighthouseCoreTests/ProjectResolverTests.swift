import Foundation
import Testing
@testable import LighthouseCore

@Suite struct ProjectResolverTests {
    @discardableResult
    func git(_ args: [String], in dir: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "HOME": NSTemporaryDirectory()]
        try! p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func makeRepo(_ scratch: Scratch, _ name: String) -> String {
        let repo = scratch.dir(name)
        #expect(git(["init", "-q", "-b", "main"], in: repo) == 0)
        scratch.write("\(name)/README.md", "x")
        git(["add", "."], in: repo)
        #expect(git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], in: repo) == 0)
        return repo
    }

    func resolver(_ scratch: Scratch, bindings: [ProjectBinding] = []) -> ProjectResolver {
        ProjectResolver(home: scratch.path, projectsRoots: [scratch.path + "/Projects"], bindings: bindings)
    }

    @Test func gitWorktreeJoinsMainRepository() throws {
        let s = Scratch()
        let repo = makeRepo(s, "Projects/alpha")
        let worktree = s.path + "/elsewhere/wt-alpha"
        #expect(git(["worktree", "add", "-q", "-b", "feature", worktree], in: repo) == 0)
        let r = resolver(s)
        let main = r.resolve(cwd: repo + "/src")
        let wt = r.resolve(cwd: worktree)
        #expect(main.kind == .git)
        #expect(wt.root == main.root)
        #expect(wt.name == "alpha")
    }

    @Test func removedWorktreeJoinsByRemoteURL() throws {
        let s = Scratch()
        let repo = makeRepo(s, "Projects/beta")
        git(["remote", "add", "origin", "git@github.com:me/beta.git"], in: repo)
        let r = resolver(s)
        let results = r.resolveAll([(repo, nil), (s.path + "/gone/worktree", "https://github.com/me/beta")])
        #expect(results[1].root == results[0].root)
    }

    @Test func explicitBindingWins() {
        let s = Scratch()
        let target = s.dir("Projects/notes")
        let loose = s.dir("Desktop/scratch/today")
        let r = resolver(s, bindings: [ProjectBinding(folder: s.path + "/Desktop/scratch", projectRoot: target)])
        let id = r.resolve(cwd: loose)
        #expect(id.kind == .bound)
        #expect(id.root == ProjectResolver.standardize(target))
    }

    @Test func nonCodeFolderUnderProjectsIsFirstClass() {
        let s = Scratch()
        let deep = s.dir("Projects/Recipes/drafts/2026")
        let id = resolver(s).resolve(cwd: deep)
        #expect(id.kind == .folder)
        #expect(id.name == "Recipes")
        #expect(id.root == ProjectResolver.standardize(s.path + "/Projects/Recipes"))
    }

    @Test func unmatchedCwdIsUnassigned() {
        let s = Scratch()
        let tmp = s.dir("tmp/run-1")
        let id = resolver(s).resolve(cwd: tmp)
        #expect(id.isUnassigned)
        #expect(id.folderPath == ProjectResolver.standardize(tmp))
        // The home folder itself is never a project, even if it were a git repo.
        #expect(resolver(s).resolve(cwd: s.path).isUnassigned)
    }

    @Test func caseVariantsAreOneProject() {
        let s = Scratch()
        s.dir("Projects/Alpha")
        let r = resolver(s)
        #expect(r.resolve(cwd: s.path + "/projects/alpha").root == r.resolve(cwd: s.path + "/Projects/Alpha").root)
    }

    @Test func sameNameDifferentRootsAreNotMerged() {
        let s = Scratch()
        let a = makeRepo(s, "Projects/app")
        let b = makeRepo(s, "Clients/app")
        let r = resolver(s)
        #expect(r.resolve(cwd: a).root != r.resolve(cwd: b).root)
    }

    @Test func remoteNormalization() {
        #expect(ProjectResolver.normalizeRemote("git@github.com:Me/Beta.git") == ProjectResolver.normalizeRemote("https://github.com/me/beta/"))
        #expect(ProjectResolver.normalizeRemote("ssh://git@github.com/me/beta.git") == "github.com/me/beta")
    }
}
