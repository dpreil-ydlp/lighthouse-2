import CoreServices
import Foundation

/// FSEvents watcher for source folders. Observes only; it never touches the files. Reports the
/// changed file paths that pass `filter`, batched by FSEvents latency.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void
    private let filter: @Sendable (String) -> Bool
    private let queue = DispatchQueue(label: "com.lighthouse.v2.fsevents")

    init?(paths: [String], latency: CFTimeInterval, filter: @escaping @Sendable (String) -> Bool,
          handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        self.filter = filter
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []).prefix(count)
            let relevant = paths.filter(watcher.filter)
            if !relevant.isEmpty { watcher.handler(Array(relevant)) }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
