import Darwin
import Foundation

/// The only place receipt captures are written (M2-01): a fixed app-owned folder,
/// `/private/tmp/lighthouse-v2-snapshots`. Captures are enabled only by the launch argument
/// `-LighthouseSnapshot <name>` (never by saved defaults, like the M1-07 test hooks).
///
/// Every path component is opened with `O_NOFOLLOW` relative to its parent, the folder is created
/// with `mkdirat` and must be a real directory owned by this user and writable by no one else, and
/// each file is created with `O_CREAT | O_EXCL | O_NOFOLLOW` after removing a previous entry of the same
/// name (`unlinkat` removes a link itself, never its target). A symlink anywhere fails closed.
enum SnapshotFolder {
    static let path = "/private/tmp/lighthouse-v2-snapshots"

    /// The capture name from the launch arguments, or nil when captures are off.
    static func name(arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "-LighthouseSnapshot"), i + 1 < arguments.count else { return nil }
        let name = arguments[i + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.isEmpty ? nil : String(name.prefix(64))
    }

    /// Writes `data` to `<folder>/<file>`. Returns false, writing nothing, if any component of
    /// `folder` is a symlink or not a directory, if the folder is not owned by this user or is group
    /// or world writable, or if `file` is not a plain name.
    @discardableResult
    static func write(_ data: Data, file: String, folder: String = path) -> Bool {
        guard !file.isEmpty, !file.contains("/"), file != ".", file != "..",
              folder.hasPrefix("/"), !folder.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        guard let dir = openFolder(folder) else { return false }
        defer { close(dir) }
        if unlinkat(dir, file, 0) != 0, errno != ENOENT { return false }
        let fd = openat(dir, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Opens `folder` one component at a time from `/` without following links; creates only the
    /// last component.
    static func openFolder(_ folder: String) -> Int32? {
        let parts = folder.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1, mkdirat(current, part, 0o700) != 0, errno != EEXIST {
                close(current)
                return nil
            }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { return nil }
            current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            close(current)
            return nil
        }
        return current
    }
}
