import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Which files under a few directory trees have changed since it was last asked.
///
/// The sweep used to find out by listing everything: both log trees, every file, a `stat` each,
/// every twenty seconds while you work — thousands of files to learn that one of them grew.
/// FSEvents already knows which one. This collects the paths it reports and hands them over on
/// the next sweep, so an unchanged tree costs nothing and a busy one costs a `stat` per file
/// that actually moved.
///
/// It never has to be right to be safe. Anything it cannot vouch for — before the stream is
/// running, after the kernel dropped events, when a watched root itself moved, on a platform
/// without FSEvents — comes back as `.unknown`, and the caller does the full listing it always
/// did. The worst a failure here can do is make the app as slow as it used to be.
final class TreeWatcher: @unchecked Sendable {

    enum Change: Equatable {
        /// Nothing is known; list the trees.
        case unknown
        /// The stream is running and reported nothing.
        case quiet
        /// These paths were created, modified, renamed or removed.
        case files(Set<String>)
    }

    private let lock = NSLock()
    private var pending = Set<String>()
    /// True until the stream has started, and again whenever events may have been lost.
    private var overflow = true
    private var running = false
    /// Each root as the kernel spells it, paired with how the caller spelled it. FSEvents reports
    /// real paths — `/private/var/…`, symlinks resolved — while Foundation's
    /// `resolvingSymlinksInPath` deliberately strips `/private`, so the two disagree exactly where
    /// a test's temporary directory lives, and anywhere a log tree is linked in from elsewhere.
    /// Reported paths are translated back so the caller only ever sees its own spelling.
    private var spellings: [(real: String, given: String)] = []
    /// Past this many paths it is cheaper, and safer, to list the trees.
    private static let limit = 4096

    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "pwe-ai-bar.tree-watcher", qos: .utility)
    #endif

    init(paths: [String]) {
        #if canImport(CoreServices)
        let roots = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        spellings = roots.map { (Self.realPath($0), $0) }.sorted { $0.real.count > $1.real.count }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray)
                as? [String] ?? []
            var lost = paths.count != count
            let drop = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged)
            for i in 0..<count where rawFlags[i] & drop != 0 { lost = true }
            watcher.record(paths, lost: lost)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
        running = true
        #endif
    }

    deinit {
        #if canImport(CoreServices)
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        #endif
    }

    /// Only the events' own thread calls this; it is internal so a test can stand in for it.
    func record(_ paths: [String], lost: Bool) {
        let paths = paths.map(translate)
        lock.lock(); defer { lock.unlock() }
        if lost || pending.count + paths.count > Self.limit {
            overflow = true; pending.removeAll()
        } else if !overflow {
            pending.formUnion(paths)
        }
    }

    private func translate(_ path: String) -> String {
        for (real, given) in spellings where real != given {
            if path == real { return given }
            if path.hasPrefix(real + "/") { return given + path.dropFirst(real.count) }
        }
        return path
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// For tests: a watcher whose roots are spelled one way and reported another.
    static func started(spellings: [(real: String, given: String)]) -> TreeWatcher {
        let w = started()
        w.spellings = spellings
        return w
    }

    /// Everything reported since the last call, and forget it. `.unknown` exactly once after a
    /// loss: the listing the caller does in answer covers whatever was dropped.
    func drain() -> Change {
        lock.lock(); defer { lock.unlock() }
        guard running else { return .unknown }
        if overflow { overflow = false; pending.removeAll(); return .unknown }
        guard !pending.isEmpty else { return .quiet }
        defer { pending.removeAll() }
        return .files(pending)
    }

    /// For tests: a watcher that behaves as if its stream had started.
    static func started() -> TreeWatcher {
        let w = TreeWatcher(paths: [])
        w.lock.lock(); w.running = true; w.overflow = false; w.lock.unlock()
        return w
    }
}
