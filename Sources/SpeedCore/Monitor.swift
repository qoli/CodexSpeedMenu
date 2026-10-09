import Foundation
import CoreServices
import Darwin

public struct MonitorDiagnostic: Equatable {
    public enum Level: Equatable {
        case debug
        case info
        case error
    }

    public let level: Level
    public let message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}

private func canonicalPath(_ path: String) -> String {
    guard let value = path.withCString({ realpath($0, nil) }) else { return path }
    defer { free(value) }; return String(cString: value)
}

public final class Monitor {
    public static let roots = ["sessions", "archived_sessions"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/\($0)").path
    }
    public let queue = DispatchQueue(label: "CodexSpeedMenu.reader", qos: .utility)
    public var onSample: ((Sample) -> Void)?
    public var onDiagnostic: ((MonitorDiagnostic) -> Void)?
    public var onStatus: ((String) -> Void)?
    public private(set) var readers: [String: Tailer] = [:]
    public private(set) var bytesRead = 0
    public private(set) var sampleCount = 0
    public private(set) var scanCount = 0
    public private(set) var notificationCount = 0
    public private(set) var errors = 0
    var dirty: Set<String> = []
    var watches: [String: DispatchSourceFileSystemObject] = [:]
    var stream: FSEventStreamRef?
    var timer: DispatchSourceTimer?
    let roots: [String]
    var lastScan = Date.distantPast
    var newest: Sample?
    var cursor = ""
    public init(roots: [String] = Monitor.roots) {
        self.roots = roots.map { canonicalPath($0) }
    }
    func sourceName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
    func diagnose(_ level: MonitorDiagnostic.Level, _ message: String) {
        onDiagnostic?(MonitorDiagnostic(level: level, message: message))
    }
    func allowed(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0 + "/") } && path.hasSuffix(".jsonl") && canonicalPath(path) == path
    }
    func add(_ path: String, reason: String) {
        guard allowed(path), readers[path] == nil else { return }
        if readers.count >= 512 {
            // Keep recently modified logs; fixed bound includes fragments and reducer state.
            let victim = readers.keys.filter { !dirty.contains($0) }.min {
                ((try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) < ((try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast)
            }
            guard let victim else {
                diagnose(.error, "source_add_blocked reason=capacity source=\(sourceName(path)) readers=\(readers.count)")
                onStatus?("Too many changing logs; some samples unavailable")
                return
            }
            diagnose(.info, "source_evicted source=\(sourceName(victim)) replacement=\(sourceName(path))")
            readers.removeValue(forKey: victim)
            watches.removeValue(forKey: victim)?.cancel()
        }
        do {
            let reader = try Tailer(path: path, fromEnd: true)
            readers[path] = reader
            diagnose(reason == "startup" ? .debug : .info, "source_added source=\(sourceName(path)) reason=\(reason) offset=\(reader.offset)")
            watch(path)
            dirty.insert(path)
        } catch {
            errors += 1
            diagnose(.error, "source_add_failed source=\(sourceName(path)) reason=\(reason) error=\(error)")
        }
    }
    func watch(_ path: String) {
        guard watches[path] == nil else { return }
        let fd = open(path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            errors += 1
            diagnose(.error, "watch_failed source=\(sourceName(path)) errno=\(errno)")
            onStatus?("File notification unavailable")
            return
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            guard let source = self.watches[path] else { return }
            let flags = source.data
            self.notificationCount += 1
            self.dirty.insert(path)
            self.diagnose(.debug, "vnode_event source=\(self.sourceName(path)) flags=\(flags.rawValue) offset=\(self.readers[path]?.offset ?? 0)")
            if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                self.diagnose(.info, "watch_invalidated source=\(self.sourceName(path)) flags=\(flags.rawValue)")
                self.watches.removeValue(forKey: path)?.cancel()
                self.readers.removeValue(forKey: path)
                if self.allowed(path) { self.add(path, reason: "watch_invalidation") }
            }
        }
        watcher.setCancelHandler { close(fd) }
        watches[path] = watcher
        watcher.resume()
        diagnose(.debug, "watch_started source=\(sourceName(path))")
    }
    func scan(reason: String) {
        scanCount += 1; lastScan = Date()
        var files: [(String, Date)] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                guard allowed(url.path), let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
                files.append((url.path, v.contentModificationDate ?? .distantPast))
                // Enumeration metadata is bounded too; oldest files are not tracked.
                if files.count > 1024 { files.sort { $0.1 > $1.1 }; files = Array(files.prefix(512)) }
            }
        }
        let before = readers.count
        for (path, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(512) { add(path, reason: reason) }
        diagnose(.info, "scan_complete reason=\(reason) candidates=\(files.count) readers_before=\(before) readers_after=\(readers.count)")
    }
    public func start() { queue.async { self.startOnQueue() } }
    func startOnQueue() {
        diagnose(.info, "monitor_start roots=\(roots.count)")
        // Descriptor ceiling applies only to this process. Keep room for 512 vnode watches.
        var limits = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limits) == 0 && limits.rlim_cur < 640 {
            limits.rlim_cur = min(limits.rlim_max, 640)
            if setrlimit(RLIMIT_NOFILE, &limits) != 0 {
                onStatus?("File descriptor limit is too low")
                errors += 1
                diagnose(.error, "descriptor_limit_failed errno=\(errno) soft=\(limits.rlim_cur) hard=\(limits.rlim_max)")
            }
        }
        // Watch before discovery so creation/append racing the initial metadata scan is queued.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<Monitor>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as! [String]
            monitor.events(list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else {
            onStatus?("File notifications unavailable")
            errors += 1
            diagnose(.error, "fsevents_create_failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            onStatus?("File notifications failed to start")
            errors += 1
            diagnose(.error, "fsevents_start_failed")
            return
        }
        diagnose(.info, "fsevents_started")
        scan(reason: "startup")
        onStatus?(readers.isEmpty ? "No local JSONL logs available" : "Waiting for a complete response")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
    }
    func events(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        notificationCount += paths.count
        for (path, flag) in zip(paths, flags) {
            diagnose(.debug, "fsevent source=\(sourceName(path)) flags=\(flag) allowed=\(allowed(path))")
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
                // Recover dropped notifications without rescanning on every event.
                diagnose(.info, "fsevents_recovery_requested source=\(sourceName(path)) flags=\(flag)")
                if Date().timeIntervalSince(lastScan) > 30 { scan(reason: "fsevents_recovery"); dirty.formUnion(readers.keys) }
            }
            if allowed(path) { add(path, reason: "fsevent"); if readers[path] != nil { dirty.insert(path) } }
            else if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0, Date().timeIntervalSince(lastScan) > 30 { scan(reason: "directory_event") }
        }
    }
    func tick() {
        // Infrequent safety discovery; normal work reads only coalesced changed files.
        if Date().timeIntervalSince(lastScan) > 300 {
            for (path, reader) in readers where !dirty.contains(path) {
                if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value,
                   size > reader.offset {
                    diagnose(.info, "missed_notification source=\(sourceName(path)) offset=\(reader.offset) size=\(size)")
                }
            }
            scan(reason: "safety")
            dirty.formUnion(readers.keys)
        }
        let sorted = Array(dirty).sorted()
        if !sorted.isEmpty { diagnose(.debug, "tick dirty=\(sorted.count) readers=\(readers.count)") }
        let work = sorted.filter { $0 > cursor } + sorted.filter { $0 <= cursor }; dirty.removeAll()
        var budget = 1024 * 1024
        var latest: Sample?
        for path in work {
            guard budget > 0 else { dirty.insert(path); continue }
            guard let reader = readers[path] else { continue }
            do {
                if watches[path] == nil { watch(path) }
                let discardedBefore = reader.discardedLines
                let resetsBefore = reader.resets
                let result = try reader.read(budget: min(256 * 1024, budget))
                cursor = path
                budget -= result.bytes; bytesRead += result.bytes
                if result.bytes > 0 || !result.samples.isEmpty || reader.discardedLines != discardedBefore || reader.resets != resetsBefore {
                    diagnose(.info, "read_complete source=\(sourceName(path)) bytes=\(result.bytes) offset=\(reader.offset) samples=\(result.samples.count) more=\(result.more) discarded_delta=\(reader.discardedLines - discardedBefore) resets_delta=\(reader.resets - resetsBefore)")
                }
                if result.more { dirty.insert(path) }
                for sample in result.samples {
                    sampleCount += 1
                    let reference = latest?.completedAt ?? newest?.completedAt ?? .distantPast
                    if sample.completedAt > reference {
                        latest = sample
                    } else {
                        diagnose(.debug, "sample_ignored thread=\(sample.threadID) completed=\(sample.completedAt.timeIntervalSince1970) reference=\(reference.timeIntervalSince1970)")
                    }
                }
            } catch {
                errors += 1
                diagnose(.error, "read_failed source=\(sourceName(path)) error=\(error)")
                readers.removeValue(forKey: path)
                watches.removeValue(forKey: path)?.cancel()
            }
        }
        if let latest {
            newest = latest
            diagnose(.info, "sample_selected thread=\(latest.threadID) source=\(sourceName(latest.source)) completed=\(latest.completedAt.timeIntervalSince1970) usage=\(latest.usageAt.timeIntervalSince1970) output=\(latest.outputTokens) tps=\(latest.tps)")
            onSample?(latest)
        }
    }
    public func stop() { queue.sync {
        diagnose(.info, "monitor_stop readers=\(readers.count) samples=\(sampleCount) errors=\(errors)")
        timer?.cancel(); timer = nil
        for watcher in watches.values { watcher.cancel() }; watches.removeAll()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    } }
    public func stats() -> [String: Int] { queue.sync {
        ["trackedFiles": readers.count, "vnodeWatches": watches.count, "bytesRead": bytesRead, "samples": sampleCount, "scans": scanCount, "notifications": notificationCount, "errors": errors,
         "fragmentBytes": readers.values.reduce(0) { $0 + $1.fragment.count }, "discardedLines": readers.values.reduce(0) { $0 + $1.discardedLines }, "resets": readers.values.reduce(0) { $0 + $1.resets }]
    } }
}
