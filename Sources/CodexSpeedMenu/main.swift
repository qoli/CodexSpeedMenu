import AppKit
import OSLog
import SpeedCore

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments
let runtimeBase = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent() : project.appendingPathComponent("dist")
let uiEvidence = runtimeBase.appendingPathComponent("Evidence")
let monitorLog = Logger(subsystem: "cc.ronniewong.CodexSpeedMenu", category: "monitor")
let uiLog = Logger(subsystem: "cc.ronniewong.CodexSpeedMenu", category: "ui")
let powerLog = Logger(subsystem: "cc.ronniewong.CodexSpeedMenu", category: "power")
let keepAwakePreferenceKey = "keepMacAwakeForCodex"

func record(_ diagnostic: MonitorDiagnostic) {
    switch diagnostic.level {
    case .debug:
        monitorLog.debug("\(diagnostic.message, privacy: .public)")
    case .info:
        monitorLog.info("\(diagnostic.message, privacy: .public)")
    case .error:
        monitorLog.error("\(diagnostic.message, privacy: .public)")
    }
}

if let index = args.firstIndex(of: "--observe-real"), args.count > index + 1 {
    let seconds = Double(args[index + 1]) ?? 30
    let monitor = Monitor()
    monitor.onDiagnostic = record
    monitor.onSample = { s in print("sample \(s.agent.rawValue) \(s.threadID) \(s.tps) token/s") }
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
    var renderedState = ""
    var refresh: Timer?
    var smoke = args.contains("--ui-smoke")
    var keepAwakeEnabled = false
    var powerEventObservers: [NSObjectProtocol] = []
    let idleSleepLease = IdleSleepLease(duration: args.firstIndex(of: "--ui-smoke-lease-seconds").flatMap {
        args.count > $0 + 1 ? Double(args[$0 + 1]) : nil
    } ?? 5 * 60, log: powerLog)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if smoke { try? FileManager.default.createDirectory(at: uiEvidence, withIntermediateDirectories: true) }
        keepAwakeEnabled = smoke ? false : UserDefaults.standard.bool(forKey: keepAwakePreferenceKey)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.setAccessibilityLabel("Coding agent response speed")
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        monitor = Monitor()
        monitor.onDiagnostic = record
        monitor.onSample = { [weak self] value in
            uiLog.info("sample_received agent=\(value.agent.rawValue, privacy: .public) thread=\(value.threadID, privacy: .public) completed=\(value.completedAt.timeIntervalSince1970) tps=\(value.tps)")
            DispatchQueue.main.async {
                guard let self, !self.smoke else { return }
                self.accept(value)
            }
        }
        monitor.onStatus = { [weak self] value in
            uiLog.info("status_changed value=\(value, privacy: .public)")
            DispatchQueue.main.async { self?.status = value; self?.render() }
        }
        startPowerEventLogging()
        render(); monitor.start()
        refresh = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.render() }
        if smoke {
            // Native acceptance hook exercises actual status item, rendered button and Quit action.
            let delay = args.firstIndex(of: "--ui-smoke-seconds").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.smokeCheck() }
        }
    }
    func accept(_ value: Sample) {
        sample = value
        if keepAwakeEnabled { idleSleepLease.renew() }
        render()
    }
    func setKeepAwakeEnabled(_ enabled: Bool) {
        keepAwakeEnabled = enabled
        if !smoke { UserDefaults.standard.set(enabled, forKey: keepAwakePreferenceKey) }
        if enabled {
            if sample.map({ Date().timeIntervalSince($0.completedAt) < 60 }) == true {
                idleSleepLease.renew()
            }
        } else {
            idleSleepLease.cancel()
        }
        let sampleAge = sample.map { Date().timeIntervalSince($0.completedAt) } ?? -1
        uiLog.info("keep_awake_setting enabled=\(enabled) lease_active=\(self.idleSleepLease.isActive) sample_age_seconds=\(sampleAge)")
    }
    func startPowerEventLogging() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, "screens_did_sleep"),
            (NSWorkspace.screensDidWakeNotification, "screens_did_wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "session_did_resign_active"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session_did_become_active")
        ]
        powerEventObservers = events.map { name, label in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.recordPowerEvent(label)
            }
        }
    }
    func recordPowerEvent(_ name: String) {
        let sampleAge = sample.map { Date().timeIntervalSince($0.completedAt) } ?? -1
        let leaseExpiresAt = idleSleepLease.expiresAt?.timeIntervalSince1970 ?? 0
        powerLog.info("workspace_power_event name=\(name, privacy: .public) keep_awake_enabled=\(self.keepAwakeEnabled) lease_active=\(self.idleSleepLease.isActive) sample_age_seconds=\(sampleAge) lease_expires_at=\(leaseExpiresAt)")
    }
    func render() {
        let fresh = sample.map { Date().timeIntervalSince($0.completedAt) < 60 } ?? false
        item.button?.title = fresh ? String(format: "%.1f", sample!.tps) : "idle"
        item.button?.toolTip = sample.map { "\($0.agent.rawValue) last completed response: \(String(format: "%.1f", $0.tps)) token/s • \($0.threadID) • \($0.completedAt.formatted())" } ?? status
        let nextState: String
        if fresh, let sample {
            nextState = "sample:\(sample.threadID):\(sample.completedAt.timeIntervalSince1970)"
        } else if let sample {
            nextState = "idle:expired:\(sample.threadID):\(sample.completedAt.timeIntervalSince1970)"
        } else {
            nextState = "idle:no_sample"
        }
        if nextState != renderedState {
            renderedState = nextState
            uiLog.info("render_state value=\(nextState, privacy: .public)")
        }
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
            text("Source \(s.agent.rawValue)")
            text("Completed \(s.completedAt.formatted(date: .abbreviated, time: .standard))")
            text("\(s.agent == .pi ? "Session" : "Thread") \(s.threadID)")
            if !s.turnID.isEmpty { text("Turn \(s.turnID)") }
            if !s.model.isEmpty { text(s.model) }
            text(URL(fileURLWithPath: s.source).lastPathComponent)
        } else { text(status) }
        text("Effective output TPS · includes reasoning")
        menu.addItem(.separator())
        let keepAwake = NSMenuItem(title: "Keep Mac Awake for Codex & Pi", action: #selector(toggleKeepAwake(_:)), keyEquivalent: "")
        keepAwake.target = self
        keepAwake.state = keepAwakeEnabled ? .on : .off
        menu.addItem(keepAwake)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Codex Speed", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
    }
    @objc func toggleKeepAwake(_ sender: NSMenuItem) {
        setKeepAwakeEnabled(!keepAwakeEnabled)
        sender.state = keepAwakeEnabled ? .on : .off
    }
    @objc func quitApp() {
        if smoke { try? Data("quit action invoked\n".utf8).write(to: uiEvidence.appendingPathComponent("quit-action.txt")) }
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        powerEventObservers.forEach(center.removeObserver)
        powerEventObservers.removeAll()
        refresh?.invalidate(); idleSleepLease.cancel(); monitor.stop()
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
            cases.append(["case": name, "title": button.title, "statusItemVisible": item.isVisible, "buttonWindowExists": button.window != nil, "textOnly": button.image == nil, "accessoryActivationPolicy": NSApp.activationPolicy() == .accessory, "buttonBounds": NSStringFromRect(button.bounds), "windowFrame": NSStringFromRect(button.window?.frame ?? .zero), "menu": item.menu!.items.map(\.title), "menuStates": item.menu!.items.map(\.state.rawValue), "menuToolTips": item.menu!.items.map { $0.toolTip ?? "" }, "menuTextWidths": item.menu!.items.map { ($0.title as NSString).size(withAttributes: [.font: item.menu!.font]).width }, "menuWidth": item.menu!.size.width, "keepAwakeEnabled": keepAwakeEnabled, "idleSleepLeaseActive": idleSleepLease.isActive, "quitTargetAttached": item.menu!.items.last?.target === self])
        }
        func toggleKeepAwakeMenuItem() {
            menuWillOpen(item.menu!)
            if let index = item.menu!.items.firstIndex(where: { $0.title == "Keep Mac Awake for Codex & Pi" }) {
                item.menu!.performActionForItem(at: index)
            }
        }
        capture("waiting")
        toggleKeepAwakeMenuItem()
        capture("awake-armed")
        // Test fixture only: verify speed and expiry render through the actual AppKit button.
        let reducer = Reducer(source: "upstream fixture (UI self-test)", threadID: "fixture")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let bytes = try? Data(contentsOf: (Bundle.main.resourceURL?.appendingPathComponent("upstream.jsonl") ?? project.appendingPathComponent("Fixtures/upstream.jsonl"))) {
            let shift = Date().timeIntervalSince1970 - 1786622419.001 - 1
            for line in bytes.split(separator: 10) {
                if var row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let text = row["timestamp"] as? String, let timestamp = formatter.date(from: text) {
                    row["timestamp"] = formatter.string(from: timestamp.addingTimeInterval(shift))
                    if let data = try? JSONSerialization.data(withJSONObject: row), let value = reducer.consume(data) { accept(value) }
                }
            }
        }
        capture("speed")
        func finish(afterLeaseExpiry: Bool) {
            if afterLeaseExpiry {
                capture("awake-lease-expired")
                toggleKeepAwakeMenuItem()
                toggleKeepAwakeMenuItem()
                capture("awake-reenabled-with-fresh-speed")
            }
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
            if keepAwakeEnabled { toggleKeepAwakeMenuItem() }
            capture("awake-disabled")
            let report: [String: Any] = ["testMode": "native AppKit self-test; fixture injection", "cases": cases, "readerStats": monitor.stats()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: uiEvidence.appendingPathComponent("ui-smoke.json")) }
            item.menu!.performActionForItem(at: item.menu!.items.count - 1)
        }
        if let index = args.firstIndex(of: "--ui-smoke-lease-seconds"),
           args.count > index + 1,
           let seconds = Double(args[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { finish(afterLeaseExpiry: true) }
        } else {
            finish(afterLeaseExpiry: false)
        }
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
