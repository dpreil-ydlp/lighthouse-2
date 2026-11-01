import Foundation
import Testing
@testable import LighthouseApp

/// M2-01: receipt captures cannot write outside their folder through symlinks, and are off unless
/// the launch arguments ask for them. Uses scratch folders only; outside "targets" are sentinels.
@Suite struct SnapshotFolderTests {
    final class Scratch {
        let path: String
        init() {
            let base = realpath(NSTemporaryDirectory(), nil).map { p in defer { free(p) }; return String(cString: p) }!
            path = base + "/lh2-snap-\(UUID().uuidString)"
            try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }
        func sentinel(_ name: String) -> String {
            let p = path + "/" + name
            try! Data("SENTINEL".utf8).write(to: URL(fileURLWithPath: p))
            return p
        }
        func contents(_ p: String) -> String? { FileManager.default.contents(atPath: p).map { String(decoding: $0, as: UTF8.self) } }
    }

    let png = Data("PNGBYTES".utf8)

    @Test func writesIntoARealPrivateFolder() {
        let s = Scratch()
        let folder = s.path + "/snaps"
        #expect(SnapshotFolder.write(png, file: "panel.png", folder: folder))
        #expect(s.contents(folder + "/panel.png") == "PNGBYTES")
        let mode = (try? FileManager.default.attributesOfItem(atPath: folder + "/panel.png")[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600)
        // A rerun replaces the earlier capture.
        #expect(SnapshotFolder.write(Data("NEW".utf8), file: "panel.png", folder: folder))
        #expect(s.contents(folder + "/panel.png") == "NEW")
    }

    @Test func symlinkedFolderIsRefused() throws {
        let s = Scratch()
        let outside = s.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let sentinel = s.sentinel("outside/panel.png")
        try FileManager.default.createSymbolicLink(atPath: s.path + "/snaps", withDestinationPath: outside)
        #expect(!SnapshotFolder.write(png, file: "panel.png", folder: s.path + "/snaps"))
        #expect(s.contents(sentinel) == "SENTINEL")
        #expect(!FileManager.default.fileExists(atPath: outside + "/other.png"))
    }

    @Test func symlinkedAncestorIsRefused() throws {
        let s = Scratch()
        let outside = s.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside + "/snaps", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.path + "/link", withDestinationPath: outside)
        #expect(!SnapshotFolder.write(png, file: "panel.png", folder: s.path + "/link/snaps"))
        #expect(!FileManager.default.fileExists(atPath: outside + "/snaps/panel.png"))
    }

    @Test func symlinkedFileIsReplacedNotFollowed() throws {
        let s = Scratch()
        let folder = s.path + "/snaps"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        let sentinel = s.sentinel("victim.txt")
        try FileManager.default.createSymbolicLink(atPath: folder + "/panel.png", withDestinationPath: sentinel)
        #expect(SnapshotFolder.write(png, file: "panel.png", folder: folder))
        #expect(s.contents(sentinel) == "SENTINEL")
        let type = try FileManager.default.attributesOfItem(atPath: folder + "/panel.png")[.type] as? FileAttributeType
        #expect(type == .typeRegular)
    }

    @Test func sharedOrForeignFolderAndBadNamesAreRefused() throws {
        let s = Scratch()
        let folder = s.path + "/snaps"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder)
        #expect(!SnapshotFolder.write(png, file: "panel.png", folder: folder))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        for bad in ["", ".", "..", "../x.png", "a/b.png"] { #expect(!SnapshotFolder.write(png, file: bad, folder: folder)) }
        #expect(!SnapshotFolder.write(png, file: "x.png", folder: s.path + "/snaps/../snaps"))
        #expect(!SnapshotFolder.write(png, file: "x.png", folder: "relative/snaps"))
    }

    @Test func capturesAreOffWithoutTheLaunchArgument() {
        #expect(SnapshotFolder.name(arguments: ["/Applications/Lighthouse.app/Contents/MacOS/Lighthouse"]) == nil)
        // The M2 candidate's directory argument no longer enables anything.
        #expect(SnapshotFolder.name(arguments: ["Lighthouse", "-LighthouseSnapshotDir", "/tmp/x"]) == nil)
        #expect(SnapshotFolder.name(arguments: ["Lighthouse", "-LighthouseSnapshot"]) == nil)
        #expect(SnapshotFolder.name(arguments: ["Lighthouse", "-LighthouseSnapshot", "../../etc/x"]) == "etcx")
        // A saved default of the same key is ignored: only the arguments are read.
        UserDefaults.standard.set("saved", forKey: "LighthouseSnapshot")
        defer { UserDefaults.standard.removeObject(forKey: "LighthouseSnapshot") }
        #expect(SnapshotFolder.name(arguments: ["Lighthouse"]) == nil)
        #expect(SnapshotFolder.path == "/private/tmp/lighthouse-v2-snapshots")
    }
}
