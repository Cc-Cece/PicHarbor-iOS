import Foundation

/// Bounded, always-on diagnostics. Only allowlisted semantic fields enter files.
final class MobileDiagnostics: @unchecked Sendable {
    static let shared = MobileDiagnostics()
    private let queue = DispatchQueue(label: "PicHarbor.diagnostics", qos: .utility)
    private let session = UUID().uuidString
    private let directory: URL
    private let limit = 64 * 1024 * 1024
    private let retention: TimeInterval = 14 * 86400
    private let formatter = ISO8601DateFormatter()
    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicHarbor/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }
    func record(_ event: String, task: String = "", fields: [String: Any] = [:]) {
        queue.async { [self] in
            let now = Date()
            let allowed = Set(["state", "error_code", "resource_count", "bytes", "stage", "foreground", "revision"])
            var safe: [String: Any] = [:]
            for (key, value) in fields where allowed.contains(key) {
                if let text = value as? String {
                    // Values are identifiers, never arbitrary exception messages or URLs.
                    if text.count <= 80 && text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) { safe[key] = text }
                } else if let number = value as? NSNumber { safe[key] = number }
            }
            let item: [String: Any] = ["schema_version": 1, "timestamp": formatter.string(from: now), "session": session,
                "event": String(event.prefix(80)), "task": task, "attrs": safe]
            do {
                prune(now)
                let files = logs()
                let last = files.last
                let size = last.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                let target = last != nil && size < 512 * 1024 ? last! : directory.appendingPathComponent("\(Int64(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString).jsonl")
                if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
                try handle.seekToEnd()
                var data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]); data.append(10)
                try handle.write(contentsOf: data)
                prune(now)
            } catch { /* Diagnostic failure cannot change backup state. */ }
        }
    }
    private func logs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func prune(_ now: Date) {
        var remaining: [(URL, Int)] = []
        for file in logs() {
            let metadata = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if now.timeIntervalSince(metadata?.contentModificationDate ?? .distantPast) >= retention { try? FileManager.default.removeItem(at: file) }
            else { remaining.append((file, metadata?.fileSize ?? 0)) }
        }
        var total = remaining.reduce(0) { $0 + $1.1 }
        for (file, size) in remaining where total > limit { try? FileManager.default.removeItem(at: file); total -= size }
    }
    func export(from: Date?, to: Date?, summary: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("PicHarbor-diagnostics-\(UUID().uuidString)", isDirectory: true)
                do {
                    prune(Date())
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    let structured = work.appendingPathComponent("events.jsonl"), readable = work.appendingPathComponent("readable.log")
                    FileManager.default.createFile(atPath: structured.path, contents: nil)
                    FileManager.default.createFile(atPath: readable.path, contents: nil)
                    let json = try FileHandle(forWritingTo: structured), text = try FileHandle(forWritingTo: readable)
                    do {
                        for file in logs() {
                            let contents = try String(contentsOf: file, encoding: .utf8)
                            for line in contents.split(separator: "\n") {
                                guard let data = line.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                      let stamp = event["timestamp"] as? String, let date = formatter.date(from: stamp),
                                      from == nil || date >= from!, to == nil || date < to! else { continue }
                                var row = data; row.append(10); try json.write(contentsOf: row)
                                let attributes = event["attrs"] as? [String: Any] ?? [:]
                                let attrs = try JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys])
                                try text.write(contentsOf: Data("\(stamp) \(event["event"] ?? "") task=\(event["task"] ?? "") \(String(decoding: attrs, as: UTF8.self))\n".utf8))
                            }
                        }
                        try json.close(); try text.close()
                    } catch { try? json.close(); try? text.close(); throw error }
                    try Data(summary.utf8).write(to: work.appendingPathComponent("summary.json"))
                    let manifest: [String: Any] = ["format": 1, "platform": "ios", "retention_days": 14, "capacity_bytes": limit,
                        "coverage": ["app_lifecycle", "native_task_persistence", "shared_core_operations"],
                        "exclusions": ["credentials", "accounts", "media", "filenames", "network_payloads"]]
                    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: work.appendingPathComponent("manifest.json"))
                    let destination = work.appendingPathExtension("zip")
                    try DiagnosticZip.write(directory: work, destination: destination)
                    try FileManager.default.removeItem(at: work)
                    continuation.resume(returning: destination)
                } catch { try? FileManager.default.removeItem(at: work); continuation.resume(throwing: error) }
            }
        }
    }
}

/// Streaming ZIP (stored entries), with CRC-32 and a central directory.
enum DiagnosticZip {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private static func header(_ values: [(UInt64, Int)]) -> Data {
        var result = Data()
        for (value, count) in values { for byte in 0..<count { result.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) } }
        return result
    }
    static func write(directory: URL, destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var central = Data(), count: UInt64 = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = Data(file.lastPathComponent.utf8), start = try output.offset()
            let size = UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size < UInt32.max, start < UInt32.max else { throw HarborError("FILE_WRITE") }
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            var crc: UInt32 = 0xffffffff
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                for byte in chunk { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
            }
            crc ^= 0xffffffff
            var local = header([(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(0,2),(UInt64(crc),4),(size,4),(size,4),(UInt64(name.count),2),(0,2)])
            local.append(name); try output.write(contentsOf: local)
            try input.seek(toOffset: 0)
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            central.append(header([(0x02014b50,4),(20,2),(20,2),(0x800,2),(0,2),(0,2),(0,2),(UInt64(crc),4),(size,4),(size,4),(UInt64(name.count),2),(0,2),(0,2),(0,2),(0,2),(0,4),(start,4)]))
            central.append(name); count += 1
        }
        let offset = try output.offset(); try output.write(contentsOf: central)
        try output.write(contentsOf: header([(0x06054b50,4),(0,2),(0,2),(count,2),(count,2),(UInt64(central.count),4),(offset,4),(0,2)]))
    }
}
