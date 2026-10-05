import Foundation

public struct Sample: Codable, Equatable {
    public var threadID: String
    public var turnID: String
    public var responseID: String?
    public var model: String
    public var startedAt: Date
    public var completedAt: Date
    public var usageAt: Date
    public var outputTokens: Int
    public var source: String
    public var seconds: Double { completedAt.timeIntervalSince(startedAt) }
    public var tps: Double { Double(outputTokens) / seconds }
}

// Port of MIT adenta/codex-tps analysis.go at be549617. Each file owns a reducer;
// session_id is deliberately never a cross-file aggregation key.
public final class Reducer {
    public let source: String
    public private(set) var threadID: String
    var threadBound = false
    var turnID = ""
    var model = ""
    var start: Date?
    var end: Date?
    var reliable = false
    var lastTotal: String?
    var lastUsage: String?
    var identity: (id: String, turn: String, usage: String, at: Date)?
    let fractional = ISO8601DateFormatter()
    let plain = ISO8601DateFormatter()
    public init(source: String, threadID: String) {
        self.source = source; self.threadID = threadID
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    public func invalidate() {
        start = nil; end = nil; reliable = false; identity = nil; lastTotal = nil; lastUsage = nil
    }
    func signature(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func consume(_ data: Data) -> Sample? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = row["timestamp"] as? String,
              let timestamp = fractional.date(from: text) ?? plain.date(from: text),
              let type = row["type"] as? String else { invalidate(); return nil }
        let p = row["payload"] as? [String: Any] ?? [:]
        let kind = p["type"] as? String ?? ""
        if let explicit = (p["thread_id"] ?? row["thread_id"]) as? String {
            // session_meta.id may name a shared parent session. The first explicit
            // thread_id binds this independent file without moving its timer.
            if threadBound && explicit != threadID { invalidate() }
            threadID = explicit; threadBound = true
        }
        switch type {
        case "session_meta":
            if let id = (p["thread_id"] ?? p["id"]) as? String { threadID = id }
        case "turn_context":
            if let id = p["turn_id"] as? String, !turnID.isEmpty, id != turnID { invalidate() }
            turnID = p["turn_id"] as? String ?? turnID
            model = p["model"] as? String ?? model
            if reliable && end == nil { start = timestamp }
        case "token_usage_record":
            // Identity only. Never emit or move a boundary from this newer record.
            if let id = p["response_id"] as? String, let usage = signature(p["usage"]) {
                identity = (id, p["turn_id"] as? String ?? turnID, usage, timestamp)
            }
        case "response_item":
            if kind == "reasoning" || (kind == "message" && p["role"] as? String == "assistant") || kind.hasSuffix("_call") {
                if reliable { end = timestamp }
            } else if end == nil && reliable && (["function_call_output", "custom_tool_call_output", "agent_message"].contains(kind) || (kind == "message" && ["user", "developer", "system"].contains(p["role"] as? String ?? ""))) {
                start = timestamp
            }
        case "event_msg":
            if kind == "task_started" {
                turnID = p["turn_id"] as? String ?? ""; start = timestamp; end = nil; reliable = true; identity = nil
            } else if kind == "user_message" {
                if reliable && end == nil { start = timestamp }
            } else if kind == "turn_aborted" || kind == "task_complete" {
                start = nil; end = nil; reliable = false; identity = nil
            } else if kind == "token_count" {
                guard let info = p["info"] as? [String: Any], let usage = info["last_token_usage"] as? [String: Any] else { return nil }
                let total = signature(info["total_token_usage"])
                // Replayed usage notifications cannot reset the timer a second time.
                if let total, total == lastTotal { return nil }
                if total == nil && end == nil && signature(usage) == lastUsage { return nil }
                lastUsage = signature(usage)
                lastTotal = total
                let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                var sample: Sample?
                if reliable, let start, let end, end > start, output > 0 {
                    let matched = identity.flatMap { $0.turn == turnID && $0.at >= end && $0.usage == signature(usage) ? $0.id : nil }
                    sample = Sample(threadID: threadID, turnID: turnID, responseID: matched, model: model, startedAt: start, completedAt: end, usageAt: timestamp, outputTokens: output, source: source)
                }
                // A witnessed old usage boundary is also a known start for the NEXT response,
                // even after cold EOF startup. The current incomplete window is never emitted.
                self.start = timestamp; end = nil; reliable = true; identity = nil
                return sample
            }
        default: break
        }
        return nil
    }
}
