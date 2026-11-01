import Foundation

/// One writer per store (M9 F3). An advisory `flock` on the store's folder itself: no lock file is
/// created, the kernel drops the lock when the process ends (also on `kill -9` or a crash), and a
/// second copy of the app on the same store, whatever its path or bundle id, cannot take it.
///
/// The app checks running copies by bundle id too; that check misses a copy with another bundle id
/// (or none, like the SwiftPM executable) and two copies launched at the same moment.
public final class StoreLock: @unchecked Sendable {
    public let directory: URL
    private let descriptor: Int32

    /// Takes the lock without waiting. Nil when another process (or another `StoreLock` in this
    /// process) holds it, or when the folder cannot be opened.
    public init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.directory = directory
        self.descriptor = fd
    }

    /// The lock for the store at `storeURL` (its folder).
    public convenience init?(store storeURL: URL) {
        self.init(directory: storeURL.deletingLastPathComponent())
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
