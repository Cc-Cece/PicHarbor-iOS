import Foundation

/// Persist the upload response independently of whether headers were delivered
/// in this process. Repeated callbacks/relaunch must not truncate received data.
struct UploadResponseStore {
    let root: URL
    static let limit: UInt64 = 4 * 1024 * 1024
    func url(_ id: Int) -> URL { root.appendingPathComponent("response-\(id).bin") }
    func prepare(_ id: Int) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = url(id)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw HarborError("UPLOAD_RESPONSE_WRITE") }
        }
    }
    func append(_ data: Data, id: Int) throws {
        try prepare(id)
        let file = try FileHandle(forWritingTo: url(id)); defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size <= Self.limit, UInt64(data.count) <= Self.limit - size else { throw HarborError("UPLOAD_RESPONSE_TOO_LARGE") }
        try file.write(contentsOf: data)
        try file.synchronize()
    }
    func validate(_ id: Int) throws {
        guard FileManager.default.fileExists(atPath: url(id).path) else { throw HarborError("UPLOAD_RESPONSE_MISSING") }
        let size = try url(id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw HarborError("UPLOAD_RESPONSE_EMPTY") }
        guard UInt64(size) <= Self.limit else { throw HarborError("UPLOAD_RESPONSE_TOO_LARGE") }
    }
}
