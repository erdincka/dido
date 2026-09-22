import Foundation
import CoreServices
import os

/// Watches the library root with FSEvents and feeds coalesced changes to the indexer.
/// Also runs the background scan at launch when auto-indexing is on.
@Observable @MainActor
final class LibraryMonitor {
    static let shared = LibraryMonitor()

    private(set) var watchedRoot: URL?
    private var watcher: FSEventWatcher?
    private let logger = Logger(subsystem: "com.dido", category: "Monitor")

    private init() {}

    /// Starts watching `root`, replacing any previous watch, and kicks off the background scan.
    func activate(root: URL?, autoIndex: Bool) {
        if watchedRoot != root {
            watcher?.stop()
            watcher = nil
            watchedRoot = root
            if let root, autoIndex {
                let watcher = FSEventWatcher(root: root) { paths in
                    Task { await DocumentIndexer.shared.applyChanges(paths: paths) }
                }
                watcher.start()
                self.watcher = watcher
                logger.info("Watching \(root.path)")
            }
        }
        if let root, autoIndex {
            Task { await DocumentIndexer.shared.index(root, quiet: true) }
        }
    }

    func deactivate() {
        watcher?.stop()
        watcher = nil
        watchedRoot = nil
    }
}

/// Thin FSEvents wrapper. Events are batched for two seconds before `onChange` runs with the affected paths.
final class FSEventWatcher: @unchecked Sendable {
    private let root: URL
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "com.dido.fsevents")
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var flush: DispatchWorkItem?

    init(root: URL, onChange: @escaping @Sendable ([String]) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var changed: [String] = []
            for index in 0..<count {
                if let path = list[index] as? String { changed.append(path) }
            }
            watcher.enqueue(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        queue.sync {
            flush?.cancel()
            flush = nil
            pending.removeAll()
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
    }

    private func enqueue(_ paths: [String]) {
        pending.formUnion(paths)
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending).sorted()
            self.pending.removeAll()
            if !batch.isEmpty { self.onChange(batch) }
        }
        flush = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    deinit {
        stop()
    }
}
