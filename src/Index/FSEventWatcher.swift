import Foundation
import CoreServices

// MARK: - FSEvents watcher

/// Watches ONE root directory with FSEvents and reports changed paths.
///
/// Events are requested from `sinceEventID` (0 = "since now"), so a restarted
/// daemon can replay what happened while it was down. The callback also receives
/// the highest event ID seen (to persist as a checkpoint) and whether the kernel
/// dropped events (meaning the overlay can no longer be trusted and the volume
/// must be rescanned).
final class FSEventWatcher {
    struct Batch {
        let changed: [String]
        /// Highest FSEvents ID in this batch (checkpoint to persist).
        let lastEventID: UInt64
        /// True when events were dropped / a subtree must be rescanned, so the
        /// incremental overlay is incomplete and a rebuild is needed.
        let needsRescan: Bool
    }

    private let root: String
    private let sinceEventID: UInt64
    private let latency: CFTimeInterval
    private let onBatch: (Batch) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "mff.fsevents")

    init(root: String, sinceEventID: UInt64, latency: CFTimeInterval = 0.2,
         onBatch: @escaping (Batch) -> Void) {
        self.root = root
        self.sinceEventID = sinceEventID
        self.latency = latency
        self.onBatch = onBatch
    }

    func start() -> Bool {
        guard !root.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIDs in
            guard let info else { return }
            let watcher = Unmanaged<FSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            let ids = UnsafeBufferPointer(start: eventIDs, count: numEvents)

            var changed: [String] = []
            changed.reserveCapacity(numEvents)
            var lastID: UInt64 = 0
            var dropped = false
            for i in 0..<numEvents {
                if let p = paths[i] as? String { changed.append(p) }
                if ids[i] > lastID { lastID = ids[i] }
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || f & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                    || f & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
                    || f & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    dropped = true
                }
            }
            watcher.onBatch(Batch(changed: changed, lastEventID: lastID, needsRescan: dropped))
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot)
        let since = sinceEventID == 0
            ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            : FSEventStreamEventId(sinceEventID)
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root] as CFArray,
            since, latency, flags)
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
