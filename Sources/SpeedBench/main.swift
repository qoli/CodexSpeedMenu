import Foundation
import SpeedCore

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments
if args.contains("--bounded-real") {
    var paths: [(URL, Date)] = []
    for root in Monitor.roots.prefix(1) {
        if let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in e where url.pathExtension == "jsonl" && url.resolvingSymlinksInPath() == url {
                if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true { paths.append((url, v.contentModificationDate ?? .distantPast)) }
                if paths.count > 1024 { paths.sort { $0.1 > $1.1 }; paths = Array(paths.prefix(512)) }
            }
        }
    }
    var total = 0; var sampleCount = 0
    for (url, _) in paths.sorted(by: { $0.1 > $1.1 }).prefix(4) {
        let handle = try FileHandle(forReadingFrom: url); let size = try handle.seekToEnd()
        let begin = size > 1024 * 1024 ? size - 1024 * 1024 : 0
        try handle.seek(toOffset: begin); let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data(); try handle.close()
        total += bytes.count
        let reader = try Tailer(path: url.path, fromEnd: true)
        let clean: Data
        if begin > 0, let newline = bytes.firstIndex(of: 10) { clean = bytes.subdata(in: (newline + 1)..<bytes.count) } else { clean = bytes }
        let samples = reader.feed(clean); sampleCount += samples.count
        print("file=\(url.lastPathComponent) boundedBytes=\(bytes.count) samples=\(samples.count) discardedLines=\(reader.discardedLines)")
        if let s = samples.last { print("last thread=\(s.threadID) output=\(s.outputTokens) seconds=\(s.seconds) tps=\(s.tps)") }
    }
    print("total boundedBytes=\(total) samples=\(sampleCount)")
} else if let index = args.firstIndex(of: "--append"), args.count > index + 1 {
    let seconds = Int(args[index + 1]) ?? 30
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexSpeedMenu-bench-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("rollout-benchmark.jsonl"); try Data().write(to: log)
    let fixture = try Data(contentsOf: project.appendingPathComponent("Fixtures/upstream.jsonl"))
    var batch = Data(); for _ in 0..<100 { batch.append(fixture) }
    let monitor = Monitor(roots: [root.path])
    let ready = DispatchSemaphore(value: 0); monitor.onStatus = { _ in ready.signal() }
    monitor.start(); guard ready.wait(timeout: .now() + 5) == .success else { fatalError("monitor did not start") }
    let handle = try FileHandle(forWritingTo: log)
    for _ in 0..<seconds {
        try handle.write(contentsOf: batch)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    try handle.close()
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    print("expectedBytes=\(batch.count * seconds) expectedSamples=\(200 * seconds)")
    print("final \(monitor.stats())"); monitor.stop()
} else { print("SpeedBench --bounded-real | --append seconds") }
