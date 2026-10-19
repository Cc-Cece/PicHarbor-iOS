import Foundation
import SQLite3

/// Sole writer of the native business database. Python keeps its legacy observations separately.
actor BackupStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        sqlite3_busy_timeout(db, 5000)
        var versionQuery: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &versionQuery, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        let version = sqlite3_step(versionQuery) == SQLITE_ROW ? sqlite3_column_int(versionQuery, 0) : -1
        sqlite3_finalize(versionQuery)
        guard version >= 0 && version <= 2 else { throw HarborError("DATABASE_VERSION_UNSUPPORTED") }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS documents(kind TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(kind,id));", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pragma_table_info('documents') WHERE name='revision'", -1, &columns, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        let hasRevision = sqlite3_step(columns) == SQLITE_ROW && sqlite3_column_int(columns, 0) == 1
        sqlite3_finalize(columns)
        if !hasRevision {
            guard sqlite3_exec(db, "ALTER TABLE documents ADD COLUMN revision INTEGER NOT NULL DEFAULT 0", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        }
        guard sqlite3_exec(db, "PRAGMA user_version=2", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
    }
    deinit { sqlite3_close(db) }
    func save<T: Encodable>(_ value: T, kind: String, id: String, revision: Int64 = 0) throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO documents(kind,id,payload,revision) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision WHERE excluded.revision>=documents.revision", -1, &statement, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_int64(statement, 4, revision)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HarborError("DATABASE_ERROR") }
    }
    func load<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM documents WHERE kind=? ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw HarborError("DATABASE_ERROR") }
            // Corrupt persisted state is an error, never an empty successful history.
            result.append(try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return result
    }
    func remove(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM documents WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HarborError("DATABASE_ERROR") }
    }
    func saveBatch<T: Encodable>(_ values: [(String, T)], kind: String) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        do {
            for (id, value) in values { try save(value, kind: kind, id: id) }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
    func saveJobs(_ jobs: [BackupJob]) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        do {
            for job in jobs { try save(job, kind: "job", id: job.id, revision: job.generation ?? 0) }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw HarborError("DATABASE_ERROR") }
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
}
