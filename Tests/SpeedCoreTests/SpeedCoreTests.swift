import XCTest
@testable import SpeedCore

final class SpeedCoreTests: XCTestCase {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixture() throws -> Data { try Data(contentsOf: project.appendingPathComponent("Fixtures/upstream.jsonl")) }
    func tempFile(_ data: Data = Data()) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-019ffb1f-f334-7e91-9a25-08d5e9e40d42.jsonl")
        try data.write(to: file); return file
    }
    func append(_ data: Data, to url: URL) throws {
        let f = try FileHandle(forWritingTo: url); try f.seekToEnd(); try f.write(contentsOf: data); try f.close()
    }
    func row(_ second: Double, _ type: String, _ payload: [String: Any]) throws -> Data {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = Date(timeIntervalSince1970: 1786622400 + second)
        var d = try JSONSerialization.data(withJSONObject: ["timestamp": f.string(from: date), "type": type, "payload": payload], options: [.sortedKeys]); d.append(10); return d
    }
    func testPinnedUpstreamSamplesExactly() throws {
        let file = try tempFile(fixture()); let reader = try Tailer(path: file.path, fromEnd: false)
        let samples = try reader.read().samples
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("Fixtures/upstream-expected.json"))) as! [[String: Any]]
        XCTAssertEqual(samples.count, expected.count)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for (sample, e) in zip(samples, expected) {
            XCTAssertEqual(sample.threadID, e["SessionID"] as? String)
            XCTAssertEqual(sample.turnID, e["TurnID"] as? String)
            XCTAssertEqual(sample.model, e["Model"] as? String)
            XCTAssertEqual(sample.outputTokens, e["OutputTokens"] as? Int)
            XCTAssertEqual(sample.seconds, e["ElapsedSeconds"] as! Double, accuracy: 0.000001)
            XCTAssertEqual(sample.startedAt, f.date(from: e["StartedAt"] as! String) ?? plain.date(from: e["StartedAt"] as! String))
            XCTAssertEqual(sample.completedAt, f.date(from: e["CompletedAt"] as! String) ?? plain.date(from: e["CompletedAt"] as! String))
            XCTAssertEqual(sample.usageAt, f.date(from: e["UsageRecordedAt"] as! String) ?? plain.date(from: e["UsageRecordedAt"] as! String))
        }
        XCTAssertEqual(samples.map(\.tps), [25, 20])
    }
    func testEveryChunkSizeAndHalfLine() throws {
        let bytes = try fixture(); let file = try tempFile()
        for width in [1, 2, 7, 31, 4096] {
            let reader = try Tailer(path: file.path, fromEnd: false); var samples: [Sample] = []
            var i = 0
            while i < bytes.count { let j = min(i + width, bytes.count); samples += reader.feed(bytes.subdata(in: i..<j)); i = j }
            XCTAssertEqual(samples.map(\.tps), [25, 20], "width \(width)")
        }
        let reader = try Tailer(path: file.path, fromEnd: false)
        let halves = try row(0, "event_msg", ["type": "task_started"])
        XCTAssertTrue(reader.feed(halves.dropLast()).isEmpty); XCTAssertNotNil(reader.fragment.first)
        XCTAssertTrue(reader.feed(Data([10])).isEmpty); XCTAssertTrue(reader.fragment.isEmpty)
    }
    func testDuplicateUsageAndNewRecordDoNotMoveBoundary() throws {
        let file = try tempFile(); let reader = try Tailer(path: file.path, fromEnd: false)
        var records = try fixture().split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        let count = records[7]["payload"] as! [String: Any]; let usage = (count["info"] as! [String: Any])["last_token_usage"]!
        let newer = try JSONSerialization.jsonObject(with: row(5.001, "token_usage_record", ["thread_id": "019ffb1f-f334-7e91-9a25-08d5e9e40d42", "turn_id": "019ffb20-1111-7111-8111-111111111111", "response_id": "r1", "usage": usage])) as! [String: Any]
        records.insert(newer, at: 6)
        var duplicate = records[8]; duplicate["timestamp"] = "2026-08-13T12:00:16.001Z"; records.insert(duplicate, at: 9)
        var samples: [Sample] = []
        for r in records { var d = try JSONSerialization.data(withJSONObject: r); d.append(10); samples += reader.feed(d) }
        XCTAssertEqual(samples.map(\.tps), [25, 20]); XCTAssertEqual(samples.first?.responseID, "r1")
    }
    func testParallelThreadsSharingParentRemainSeparate() throws {
        let a = try Tailer(path: tempFile().path, fromEnd: false); let b = try Tailer(path: tempFile().path, fromEnd: false)
        let lines = try fixture().split(separator: 10)
        var asamples: [Sample] = []; var bsamples: [Sample] = []
        for l in lines {
            var ad = Data(l); ad.append(10); asamples += a.feed(ad)
            var r = try JSONSerialization.jsonObject(with: Data(l)) as! [String: Any]; var p = r["payload"] as! [String: Any]
            p["thread_id"] = "child-thread"; p["session_id"] = "019ffb1f-f334-7e91-9a25-08d5e9e40d42"
            if r["type"] as? String == "session_meta" { p["id"] = "child-thread" }
            r["payload"] = p; var bd = try JSONSerialization.data(withJSONObject: r); bd.append(10); bsamples += b.feed(bd)
        }
        XCTAssertEqual(asamples.map(\.tps), [25, 20]); XCTAssertEqual(bsamples.map(\.tps), [25, 20])
        XCTAssertEqual(bsamples.map(\.threadID), ["child-thread", "child-thread"])
    }
    func testChildSharedParentMetadataBindsFirstIdentityWithoutReset() throws {
        let reader = try Tailer(path: tempFile().path, fromEnd: false)
        var rows = try fixture().split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        let usage = ((rows[7]["payload"] as! [String: Any])["info"] as! [String: Any])["last_token_usage"]!
        let identity = try JSONSerialization.jsonObject(with: row(5.001, "token_usage_record", ["thread_id": "child", "session_id": "019ffb1f-f334-7e91-9a25-08d5e9e40d42", "turn_id": "019ffb20-1111-7111-8111-111111111111", "response_id": "child-r1", "usage": usage])) as! [String: Any]
        rows.insert(identity, at: 6)
        var samples: [Sample] = []
        for row in rows { var data = try JSONSerialization.data(withJSONObject: row); data.append(10); samples += reader.feed(data) }
        XCTAssertEqual(samples.map(\.tps), [25, 20])
        XCTAssertEqual(samples.map(\.threadID), ["child", "child"])
        XCTAssertEqual(samples.first?.responseID, "child-r1")
    }
    func testRestartStartsAtEOFAndSkipsInFlightPartialWindow() throws {
        let data = try fixture(); let file = try tempFile(data)
        let half = try row(30, "event_msg", ["type": "task_started", "turn_id": "unseen"])
        try append(half.dropLast(), to: file)
        let restarted = try Tailer(path: file.path, fromEnd: true)
        XCTAssertEqual(restarted.offset, UInt64(data.count + half.count - 1))
        try append(Data([10]), to: file)
        try append(row(34, "response_item", ["type": "message", "role": "assistant"]), to: file)
        try append(row(35, "event_msg", ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 40], "total_token_usage": ["output_tokens": 40]]]), to: file)
        XCTAssertTrue(try restarted.read().samples.isEmpty)
        try append(row(39, "response_item", ["type": "message", "role": "assistant"]), to: file)
        try append(row(40, "event_msg", ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 60], "total_token_usage": ["output_tokens": 100]]]), to: file)
        XCTAssertEqual(try restarted.read().samples.map(\.tps), [15])
    }
    func testTruncateDropsWindowAndWaitsForNewCompleteResponse() throws {
        let data = try fixture(); let file = try tempFile(data); let reader = try Tailer(path: file.path, fromEnd: false)
        _ = try reader.read()
        try Data().write(to: file)
        XCTAssertTrue(try reader.read().samples.isEmpty)
        XCTAssertEqual(reader.offset, 0); XCTAssertEqual(reader.resets, 1)
        try append(data, to: file)
        XCTAssertEqual(try reader.read().samples.map(\.tps), [25, 20])
    }
    func testGiantLineBoundThenWaitForCompleteWindow() throws {
        let r = try Tailer(path: tempFile().path, fromEnd: false)
        for _ in 0..<160 { _ = r.feed(Data(repeating: 65, count: 65536)); XCTAssertLessThanOrEqual(r.fragment.count, Tailer.maxLine) }
        XCTAssertEqual(r.discardedLines, 1); XCTAssertTrue(r.feed(Data([10])).isEmpty)
        XCTAssertEqual(r.feed(try fixture()).map(\.tps), [25, 20])
    }
    func testColdTailMissingWindowAbortAndInvalidDuration() throws {
        let f = try tempFile(fixture()); let r = try Tailer(path: f.path, fromEnd: true)
        XCTAssertTrue(try r.read().samples.isEmpty); XCTAssertEqual(r.bytesRead, 0)
        _ = r.feed(try row(1, "response_item", ["type": "message", "role": "assistant"]))
        let usage: [String: Any] = ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 10], "total_token_usage": ["output_tokens": 10]]]
        XCTAssertTrue(r.feed(try row(2, "event_msg", usage)).isEmpty)
        _ = r.feed(try row(3, "event_msg", ["type": "turn_aborted"]))
        _ = r.feed(try row(4, "response_item", ["type": "reasoning"]))
        XCTAssertTrue(r.feed(try row(5, "event_msg", usage)).isEmpty)
        _ = r.feed(try row(10, "event_msg", ["type": "task_started"]))
        _ = r.feed(try row(9, "response_item", ["type": "reasoning"]))
        var u = usage; u["info"] = ["last_token_usage": ["output_tokens": 20], "total_token_usage": ["output_tokens": 20]]
        XCTAssertTrue(r.feed(try row(11, "event_msg", u)).isEmpty)
    }
    func testReadBudgetAndSymlinkRejection() throws {
        let f = try tempFile(Data(repeating: 32, count: 2 * 1024 * 1024)); let r = try Tailer(path: f.path, fromEnd: false)
        let read = try r.read(budget: 16384); XCTAssertEqual(read.bytes, 16384); XCTAssertTrue(read.more)
        let link = f.deletingLastPathComponent().appendingPathComponent("link.jsonl"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f)
        XCTAssertThrowsError(try Tailer(path: link.path, fromEnd: false))
    }
}

final class MonitorIntegrationTests: XCTestCase {
    func testActualFSEventsAppendPublishesLatestResponse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = SpeedCoreTests()
        let log = root.appendingPathComponent("rollout-test.jsonl")
        try Data().write(to: log)
        let monitor = Monitor(roots: [root.path])
        let diagnosticLock = NSLock()
        var diagnostics: [MonitorDiagnostic] = []
        monitor.onDiagnostic = {
            diagnosticLock.lock(); diagnostics.append($0); diagnosticLock.unlock()
            print("\($0.level) \($0.message)")
        }
        print("root \(root.path) resolved \(root.resolvingSymlinksInPath().path)")
        let ready = expectation(description: "startup"); let observed = expectation(description: "sample")
        monitor.onStatus = { _ in ready.fulfill() }
        monitor.onSample = { sample in XCTAssertEqual(sample.tps, 20); observed.fulfill() }
        monitor.start(); wait(for: [ready], timeout: 5)
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        try writer.write(contentsOf: helper.fixture())
        // Keep writer OPEN: vnode notification must arrive before close/tool drain.
        wait(for: [observed], timeout: 8)
        let stats = monitor.stats(); monitor.stop()
        XCTAssertEqual(stats["samples"], 2); XCTAssertEqual(stats["scans"], 1)
        XCTAssertEqual(stats["bytesRead"], try helper.fixture().count)
        XCTAssertGreaterThan(stats["notifications"]!, 0)
        XCTAssertEqual(stats["errors"], 0)
        diagnosticLock.lock(); let captured = diagnostics; diagnosticLock.unlock()
        XCTAssertTrue(captured.contains { $0.message.contains("source_added source=rollout-test.jsonl") })
        XCTAssertTrue(captured.contains { $0.message.contains("watch_started source=rollout-test.jsonl") })
        XCTAssertTrue(captured.contains { $0.message.contains("read_complete source=rollout-test.jsonl") && $0.message.contains("samples=2") })
        XCTAssertTrue(captured.contains { $0.message.contains("sample_selected agent=Codex thread=019ffb1f-f334-7e91-9a25-08d5e9e40d42") })
        XCTAssertFalse(captured.contains { $0.message.contains(root.path) })
    }

    func testSafetyScanDiagnosesPendingBytesWithoutNotification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("rollout-missed.jsonl")
        try Data().write(to: log)
        let monitor = Monitor(roots: [root.path])
        let monitoredPath = URL(fileURLWithPath: monitor.roots[0]).appendingPathComponent(log.lastPathComponent).path
        var diagnostics: [MonitorDiagnostic] = []
        monitor.onDiagnostic = { diagnostics.append($0) }
        monitor.queue.sync {
            monitor.add(monitoredPath, reason: "test")
            monitor.dirty.removeAll()
        }
        let helper = SpeedCoreTests()
        try helper.append(helper.fixture(), to: log)
        monitor.queue.sync {
            // Model the failure boundary directly: bytes exist, but no path is queued.
            monitor.dirty.removeAll()
            monitor.lastScan = Date(timeIntervalSinceNow: -301)
            monitor.tick()
        }
        monitor.stop()
        XCTAssertTrue(diagnostics.contains {
            $0.level == .info && $0.message.contains("missed_notification source=rollout-missed.jsonl offset=0 size=")
        }, diagnostics.map(\.message).joined(separator: "\n"))
    }
}
