import Foundation
import Darwin

public final class Tailer {
    public static let maxLine = 64 * 1024
    public let path: String
    public let reducer: Reducer
    public private(set) var offset: UInt64 = 0
    public private(set) var fragment = Data()
    public private(set) var discardedLines = 0
    public private(set) var bytesRead = 0
    public private(set) var resets = 0
    var discarding = false
    public init(path: String, fromEnd: Bool) throws {
        self.path = path
        // Filename identity is only a fallback. Session metadata / explicit thread_id supersedes it.
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let uuid = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        let uuidMatch = uuid.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename))
        let piPrefix = try! NSRegularExpression(pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{3}Z_(.+)$")
        let piMatch = piPrefix.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename))
        let id = uuidMatch.flatMap { Range($0.range, in: filename).map { String(filename[$0]) } }
            ?? piMatch.flatMap { Range($0.range(at: 1), in: filename).map { String(filename[$0]) } }
            ?? filename
        reducer = Reducer(source: path, threadID: id)
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EACCES) }; defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EINVAL) }
        if fromEnd {
            offset = UInt64(st.st_size)
            discarding = Self.endsInsideLine(fd, offset)
        }
    }
    static func endsInsideLine(_ fd: Int32, _ offset: UInt64) -> Bool {
        guard offset > 0 else { return false }
        var byte: UInt8 = 10
        return pread(fd, &byte, 1, off_t(offset - 1)) == 1 && byte != 10
    }
    public func feed(_ bytes: Data) -> [Sample] {
        var result: [Sample] = []
        for byte in bytes {
            if byte == 10 {
                if !discarding, !fragment.isEmpty, let sample = reducer.consume(fragment) { result.append(sample) }
                fragment.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if fragment.count < Self.maxLine { fragment.append(byte) }
                else { fragment.removeAll(keepingCapacity: true); discarding = true; discardedLines += 1; reducer.invalidate() }
            }
        }
        return result
    }
    public func read(budget: Int = 256 * 1024) throws -> (samples: [Sample], more: Bool, bytes: Int) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }; defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EINVAL) }
        if UInt64(st.st_size) < offset {
            offset = UInt64(st.st_size); fragment.removeAll(); discarding = Self.endsInsideLine(fd, offset); reducer.invalidate(); resets += 1
        }
        let count = min(budget, Int(max(0, st.st_size - Int64(offset))))
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n >= 0 else { throw POSIXError(.EIO) }
        data = Data(data.prefix(n)); offset += UInt64(n); bytesRead += n
        return (feed(data), offset < UInt64(st.st_size), n)
    }
}
