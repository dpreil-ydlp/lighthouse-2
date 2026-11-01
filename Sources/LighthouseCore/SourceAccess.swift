import Darwin
import Foundation

/// File identity and size from `fstatat(2)`.
public struct FileStat: Sendable, Hashable, Codable {
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var mtime: Double
    public var isDirectory: Bool
    public var isSymlink: Bool = false
}

/// One file found by a directory-relative scan.
public struct ScannedFile: Sendable, Hashable {
    public var path: String
    public var stat: FileStat
    public var readable: Bool
}

/// Whether a source root can be read inside the boundary.
public enum RootCheck: Sendable, Hashable {
    case ok
    case missing
    /// The root or one of its ancestors is a symbolic link; Lighthouse does not follow it.
    case symlinked

    func message(_ root: String) -> String? {
        switch self {
        case .ok: nil
        case .missing: "Folder not found: \(root)"
        case .symlinked: "Not read: \(root) is or sits under a symbolic link"
        }
    }
}

/// The only way collectors touch source files (V-T3DB). Every operation is read-only: stat,
/// directory listing, readability check, and `pread`. There is no write, copy, move, or delete
/// operation on this type, so a collector cannot alter or duplicate a source path.
///
/// Boundary: no operation follows a symbolic link in any path component. Paths are resolved one
/// component at a time from `/` with `openat(…, O_NOFOLLOW)`, so a symlinked root, a symlinked
/// ancestor, or a directory swapped for a link after discovery fails instead of redirecting a read.
public protocol SourceAccess: Sendable {
    /// Metadata of the final component, not following it. Nil when an ancestor is a link or missing.
    func stat(_ path: String) -> FileStat?
    func list(_ directory: String) -> [String]
    /// True when the file opens for reading inside the boundary.
    func isReadable(_ path: String) -> Bool
    /// Reads up to `count` bytes at `offset`. Nil on any failure.
    func read(_ path: String, offset: UInt64, count: Int) -> Data?
    /// Recursive discovery of files ending in `.ext` under `root`, skipping hidden entries and folder
    /// names in `skipping`. Symlinked entries are counted, never followed. Each directory is opened
    /// relative to its parent descriptor with `O_NOFOLLOW`; each file gets one `fstatat` and one
    /// readability check relative to its directory.
    func scan(_ root: String, ext: String, skipping: Set<String>) -> (files: [ScannedFile], symlinks: Int)
}

public struct ReadOnlyFileSystem: SourceAccess {
    public init() {}

    public func stat(_ path: String) -> FileStat? {
        let result: FileStat?? = Boundary.withParent(of: path) { parent, name in
            var info = Darwin.stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return Self.fileStat(info)
        }
        return result ?? nil
    }

    public func list(_ directory: String) -> [String] {
        guard let fd = Boundary.open(directory, flags: O_RDONLY | O_DIRECTORY) else { return [] }
        guard let dir = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            var raw = entry.pointee.d_name
            let name = withUnsafeBytes(of: &raw) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func isReadable(_ path: String) -> Bool {
        guard let fd = Boundary.open(path, flags: O_RDONLY | O_NONBLOCK) else { return false }
        close(fd)
        return true
    }

    public func read(_ path: String, offset: UInt64, count: Int) -> Data? {
        guard let fd = Boundary.open(path, flags: O_RDONLY | O_NONBLOCK) else { return nil }
        defer { close(fd) }
        // Bypass the page cache: indexing streams gigabytes once, and caching them would evict other
        // apps' pages and could slow the window server and panel opens.
        _ = fcntl(fd, F_NOCACHE, 1)
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n >= 0 else { return nil }
        data.count = n
        return data
    }

    public func scan(_ root: String, ext: String, skipping: Set<String>) -> (files: [ScannedFile], symlinks: Int) {
        guard let rootFD = Boundary.open(root, flags: O_RDONLY | O_DIRECTORY) else { return ([], 0) }
        var files: [ScannedFile] = []
        var symlinks = 0
        var stack: [(fd: Int32, path: String)] = [(rootFD, root)]
        let suffix = "." + ext
        while let (fd, path) = stack.popLast() {
            defer { close(fd) }
            for name in Self.names(in: fd) where !name.hasPrefix(".") {
                var info = Darwin.stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let child = Self.join(path, name)
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    symlinks += 1
                case S_IFDIR:
                    guard !skipping.contains(name) else { continue }
                    let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if sub >= 0 { stack.append((sub, child)) }
                case S_IFREG where name.hasSuffix(suffix):
                    let readable = faccessat(fd, name, R_OK, AT_SYMLINK_NOFOLLOW) == 0
                    files.append(ScannedFile(path: child, stat: Self.fileStat(info), readable: readable))
                default:
                    continue
                }
            }
        }
        return (files, symlinks)
    }

    /// `directory/name` as a native Swift string. `NSString.appendingPathComponent` returns a bridged
    /// `NSPathStore2`, and every Set or Dictionary lookup of such a path takes a slow normalizing path,
    /// which adds up over a rescan of many files.
    static func join(_ directory: String, _ name: String) -> String {
        var path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
        path.makeContiguousUTF8()
        return path
    }

    /// Entry names of an open directory; the descriptor stays open for the caller.
    private static func names(in fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            var raw = entry.pointee.d_name
            let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    static func fileStat(_ info: Darwin.stat) -> FileStat {
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return FileStat(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), size: UInt64(info.st_size),
                        mtime: mtime, isDirectory: (info.st_mode & S_IFMT) == S_IFDIR, isSymlink: (info.st_mode & S_IFMT) == S_IFLNK)
    }
}

/// Component-wise, no-follow path resolution.
enum Boundary {
    /// Opens each ancestor directory of `path` from `/` with `O_NOFOLLOW`, then calls `body` with the
    /// parent descriptor and the final name. Nil when the path is relative, uses `.`/`..`, or an
    /// ancestor is missing or a link.
    static func withParent<T>(of path: String, _ body: (Int32, String) -> T) -> T? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), let last = components.last,
              !components.contains("."), !components.contains("..") else { return nil }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for component in components.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        defer { close(fd) }
        return body(fd, last)
    }

    /// Opens the final component with `O_NOFOLLOW` inside the no-follow ancestor chain.
    static func open(_ path: String, flags: Int32) -> Int32? {
        guard let fd = withParent(of: path, { parent, name in openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC) }),
              fd >= 0 else { return nil }
        return fd
    }
}

extension SourceAccess {
    /// Diagnoses a root: usable, missing, or symlinked (itself or an ancestor).
    func checkRoot(_ root: String) -> RootCheck {
        if let info = stat(root) {
            if info.isSymlink { return .symlinked }
            return info.isDirectory ? .ok : .missing
        }
        // `stat` fails when an ancestor is a link; find which case applies for the message.
        var prefix = ""
        for component in root.split(separator: "/") {
            prefix += "/" + component
            guard let info = stat(prefix) else { return .missing }
            if info.isSymlink { return .symlinked }
        }
        return .missing
    }
}
