import Foundation
import CoreServices
import Darwin

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
    public var onDiagnostic: ((String) -> Void)?
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
    func allowed(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0 + "/") } && path.hasSuffix(".jsonl") && canonicalPath(path) == path
    }
    func add(_ path: String) {
        guard allowed(path), readers[path] == nil else { return }
        if readers.count >= 512 {
            // Keep recently modified logs; fixed bound includes fragments and reducer state.
            let victim = readers.keys.filter { !dirty.contains($0) }.min {
                ((try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) < ((try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast)
            }
            guard let victim else { onStatus?("Too many changing logs; some samples unavailable"); return }
            readers.removeValue(forKey: victim)
            watches.removeValue(forKey: victim)?.cancel()
        }
        do {
            readers[path] = try Tailer(path: path, fromEnd: true)
            watch(path)
            dirty.insert(path)
        } catch { errors += 1 }
    }
    func watch(_ path: String) {
        guard watches[path] == nil else { return }
        let fd = open(path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { errors += 1; onStatus?("File notification unavailable"); return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            self.notificationCount += 1; self.dirty.insert(path)
            if let source = self.watches[path], !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                self.watches.removeValue(forKey: path)?.cancel()
                self.readers.removeValue(forKey: path)
                if self.allowed(path) { self.add(path) }
            }
        }
        watcher.setCancelHandler { close(fd) }
        watches[path] = watcher; watcher.resume()
    }
    func scan() {
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
        for (path, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(512) { add(path) }
    }
    public func start() { queue.async { self.startOnQueue() } }
    func startOnQueue() {
        // Descriptor ceiling applies only to this process. Keep room for 512 vnode watches.
        var limits = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limits) == 0 && limits.rlim_cur < 640 {
            limits.rlim_cur = min(limits.rlim_max, 640)
            if setrlimit(RLIMIT_NOFILE, &limits) != 0 { onStatus?("File descriptor limit is too low"); errors += 1 }
        }
        // Watch before discovery so creation/append racing the initial metadata scan is queued.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<Monitor>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as! [String]
            monitor.events(list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { onStatus?("File notifications unavailable"); errors += 1; return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { onStatus?("File notifications failed to start"); errors += 1; return }
        scan()
        onStatus?(readers.isEmpty ? "No local JSONL logs available" : "Waiting for a complete response")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
    }
    func events(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        notificationCount += paths.count
        for (path, flag) in zip(paths, flags) {
            onDiagnostic?("event path=\(path) flags=\(flag) allowed=\(allowed(path))")
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
                // Recover dropped notifications without rescanning on every event.
                if Date().timeIntervalSince(lastScan) > 30 { scan(); dirty.formUnion(readers.keys) }
            }
            if allowed(path) { add(path); if readers[path] != nil { dirty.insert(path) } }
            else if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0, Date().timeIntervalSince(lastScan) > 30 { scan() }
        }
    }
    func tick() {
        // Infrequent safety discovery; normal work reads only coalesced changed files.
        if Date().timeIntervalSince(lastScan) > 300 { scan(); dirty.formUnion(readers.keys) }
        let sorted = Array(dirty).sorted()
        onDiagnostic?("tick dirty=\(sorted.count) readers=\(readers.count)")
        let work = sorted.filter { $0 > cursor } + sorted.filter { $0 <= cursor }; dirty.removeAll()
        var budget = 1024 * 1024
        var latest: Sample?
        for path in work {
            guard budget > 0 else { dirty.insert(path); continue }
            guard let reader = readers[path] else { continue }
            do {
                if watches[path] == nil { watch(path) }
                let result = try reader.read(budget: min(256 * 1024, budget))
                cursor = path
                budget -= result.bytes; bytesRead += result.bytes
                onDiagnostic?("read path=\(path) bytes=\(result.bytes) samples=\(result.samples.count)")
                if result.more { dirty.insert(path) }
                for sample in result.samples {
                    sampleCount += 1
                    if sample.completedAt > (latest?.completedAt ?? newest?.completedAt ?? .distantPast) { latest = sample }
                }
            } catch {
                errors += 1
                readers.removeValue(forKey: path)
                watches.removeValue(forKey: path)?.cancel()
            }
        }
        if let latest { newest = latest; onSample?(latest) }
    }
    public func stop() { queue.sync {
        timer?.cancel(); timer = nil
        for watcher in watches.values { watcher.cancel() }; watches.removeAll()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    } }
    public func stats() -> [String: Int] { queue.sync {
        ["trackedFiles": readers.count, "vnodeWatches": watches.count, "bytesRead": bytesRead, "samples": sampleCount, "scans": scanCount, "notifications": notificationCount, "errors": errors,
         "fragmentBytes": readers.values.reduce(0) { $0 + $1.fragment.count }, "discardedLines": readers.values.reduce(0) { $0 + $1.discardedLines }, "resets": readers.values.reduce(0) { $0 + $1.resets }]
    } }
}
