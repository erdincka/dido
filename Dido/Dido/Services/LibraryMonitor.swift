import Foundation
import CoreServices
import os

/// Watches every active library folder with FSEvents and feeds coalesced changes to the indexer.
/// Also runs the background scan of a library when it starts being watched, if auto-indexing is on.
@Observable @MainActor
final class LibraryMonitor {
    static let shared = LibraryMonitor()

    private(set) var watchedRoots: [UUID: URL] = [:]
    private var watchers: [UUID: FSEventWatcher] = [:]
    private let logger = Logger(subsystem: "com.dido", category: "Monitor")

    private init() {}

    /// Watches `libraries`, dropping watches for libraries that were removed or moved, and scans newly watched ones.
    func activate(_ libraries: [(id: UUID, root: URL)], autoIndex: Bool) {
        let extra = IndexSettings.shared.excludePatterns
        let roots = libraries.map { (root: $0.root, rules: IgnoreRules.load(root: $0.root, extra: extra)) }
        Task { await FileSystemScanner.shared.configure(roots: roots) }

        for (id, root) in watchedRoots where !autoIndex || !libraries.contains(where: { $0.id == id && $0.root == root }) {
            stop(id)
        }
        guard autoIndex else { return }

        var toScan: [URL] = []
        for library in libraries where watchedRoots[library.id] == nil {
            let watcher = FSEventWatcher(root: library.root) { paths in
                Task { await DocumentIndexer.shared.applyChanges(paths: paths) }
            }
            watcher.start()
            watchers[library.id] = watcher
            watchedRoots[library.id] = library.root
            toScan.append(library.root)
            logger.info("Watching \(library.root.path)")
        }
        guard !toScan.isEmpty else { return }
        Task {
            for root in toScan {
                await DocumentIndexer.shared.index(root, quiet: true, reason: .background)
            }
        }
    }

    func deactivate() {
        for id in Array(watchers.keys) { stop(id) }
    }

    private func stop(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        watchedRoots[id] = nil
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
