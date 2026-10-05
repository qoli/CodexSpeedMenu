import AppKit
import SpeedCore

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments
let runtimeBase = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent() : project.appendingPathComponent("dist")
let uiEvidence = runtimeBase.appendingPathComponent("Evidence")

if let index = args.firstIndex(of: "--observe-real"), args.count > index + 1 {
    let seconds = Double(args[index + 1]) ?? 30
    let monitor = Monitor()
    monitor.onSample = { s in print("sample \(s.threadID) \(s.tps) token/s") }
    monitor.start()
    let begin = Date()
    while Date().timeIntervalSince(begin) < seconds {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("stats \(monitor.stats())")
    }
    monitor.stop(); print("final \(monitor.stats())"); exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var monitor: Monitor!
    var sample: Sample?
    var status = "Waiting for a complete response"
    var refresh: Timer?
    var smoke = args.contains("--ui-smoke")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if smoke { try? FileManager.default.createDirectory(at: uiEvidence, withIntermediateDirectories: true) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.setAccessibilityLabel("Codex response speed")
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        monitor = Monitor()
        monitor.onSample = { [weak self] value in DispatchQueue.main.async { self?.sample = value; self?.render() } }
        monitor.onStatus = { [weak self] value in DispatchQueue.main.async { self?.status = value; self?.render() } }
        render(); monitor.start()
        refresh = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.render() }
        if smoke {
            // Native acceptance hook exercises actual status item, rendered button and Quit action.
            let delay = args.firstIndex(of: "--ui-smoke-seconds").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.smokeCheck() }
        }
    }
    func render() {
        let fresh = sample.map { Date().timeIntervalSince($0.completedAt) < 60 } ?? false
        item.button?.title = fresh ? String(format: "%.1f", sample!.tps) : "idle"
        item.button?.toolTip = sample.map { "Last completed response: \(String(format: "%.1f", $0.tps)) token/s • \($0.threadID) • \($0.completedAt.formatted())" } ?? status
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        func text(_ value: String) {
            let maxWidth: CGFloat = 420
            let characters = Array(value)
            var title = value
            var retainedLength = characters.count
            while (title as NSString).size(withAttributes: [.font: menu.font]).width > maxWidth {
                retainedLength -= 1
                title = String(characters.prefix((retainedLength + 1) / 2)) + "…" + String(characters.suffix(retainedLength / 2))
            }
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.toolTip = title != value ? value : nil
            row.isEnabled = false
            menu.addItem(row)
        }
        if let s = sample {
            text(String(format: "Last completed: %.1f token/s", s.tps))
            text("Completed \(s.completedAt.formatted(date: .abbreviated, time: .standard))")
            text("Thread \(s.threadID)")
            if !s.turnID.isEmpty { text("Turn \(s.turnID)") }
            if !s.model.isEmpty { text(s.model) }
            text(URL(fileURLWithPath: s.source).lastPathComponent)
        } else { text(status) }
        text("Effective output TPS · includes reasoning")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Codex Speed", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
    }
    @objc func quitApp() {
        if smoke { try? Data("quit action invoked\n".utf8).write(to: uiEvidence.appendingPathComponent("quit-action.txt")) }
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        refresh?.invalidate(); monitor.stop()
        if smoke { try? Data("applicationWillTerminate reached\n".utf8).write(to: uiEvidence.appendingPathComponent("quit-termination.txt")) }
    }
    func smokeCheck() {
        var cases: [[String: Any]] = []
        func capture(_ name: String) {
            render(); menuWillOpen(item.menu!)
            let button = item.button!
            if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: uiEvidence.appendingPathComponent("status-\(name).png"))
            }
            cases.append(["case": name, "title": button.title, "statusItemVisible": item.isVisible, "buttonWindowExists": button.window != nil, "textOnly": button.image == nil, "accessoryActivationPolicy": NSApp.activationPolicy() == .accessory, "buttonBounds": NSStringFromRect(button.bounds), "windowFrame": NSStringFromRect(button.window?.frame ?? .zero), "menu": item.menu!.items.map(\.title), "menuToolTips": item.menu!.items.map { $0.toolTip ?? "" }, "menuTextWidths": item.menu!.items.map { ($0.title as NSString).size(withAttributes: [.font: item.menu!.font]).width }, "menuWidth": item.menu!.size.width, "quitTargetAttached": item.menu!.items.last?.target === self])
        }
        capture("waiting")
        // Test fixture only: verify speed and expiry render through the actual AppKit button.
        let reducer = Reducer(source: "upstream fixture (UI self-test)", threadID: "fixture")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let bytes = try? Data(contentsOf: (Bundle.main.resourceURL?.appendingPathComponent("upstream.jsonl") ?? project.appendingPathComponent("Fixtures/upstream.jsonl"))) {
            let shift = Date().timeIntervalSince1970 - 1786622419.001 - 1
            for line in bytes.split(separator: 10) {
                if var row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let text = row["timestamp"] as? String, let timestamp = formatter.date(from: text) {
                    row["timestamp"] = formatter.string(from: timestamp.addingTimeInterval(shift))
                    if let data = try? JSONSerialization.data(withJSONObject: row), let value = reducer.consume(data) { sample = value }
                }
            }
        }
        capture("speed")
        if var long = sample {
            long.source = "rollout-2026-08-13T12-00-00-01111111-2222-7333-8444-555555555555_01666666-7777-7888-8999-000000000000.jsonl"
            long.model = String(repeating: "模型👩🏽‍💻", count: 30)
            sample = long
        }
        capture("long-metadata")
        if var old = sample {
            old.startedAt = old.startedAt.addingTimeInterval(-120); old.completedAt = old.completedAt.addingTimeInterval(-120); old.usageAt = old.usageAt.addingTimeInterval(-120); sample = old
        }
        capture("expired")
        let report: [String: Any] = ["testMode": "native AppKit self-test; fixture injection", "cases": cases, "readerStats": monitor.stats()]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: uiEvidence.appendingPathComponent("ui-smoke.json")) }
        item.menu!.performActionForItem(at: item.menu!.items.count - 1)
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
