import Foundation
import SQLite3

/// Clear only quarantine history rows present in a consistent recovery snapshot, preserving new rows.
enum SQLiteLogCleaner {
    static func validate(path: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw CleanerError.message("No se pudo consultar el historial de cuarentena.")
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(connection, "SELECT LSQuarantineEventIdentifier FROM LSQuarantineEvent LIMIT 0", -1, &statement, nil) == SQLITE_OK else {
            throw CleanerError.message("Esquema de cuarentena desconocido; no se modifica.")
        }
    }
    static func clean(path: String, recoveryDirectory: URL? = nil) throws -> URL {
        let root = recoveryDirectory ?? Storage().directory.appendingPathComponent("Recovery")
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupURL = folder.appendingPathComponent("QuarantineEvents.sqlite")
        var source: OpaquePointer?
        guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw CleanerError.message("No se pudo abrir el historial de cuarentena para escritura.")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 1000)
        // Prepare first: a new or incompatible schema is never modified.
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(source, "SELECT LSQuarantineEventIdentifier FROM LSQuarantineEvent LIMIT 0", -1, &check, nil) == SQLITE_OK else {
            throw CleanerError.message("Esquema de cuarentena desconocido; no se modifica.")
        }
        sqlite3_finalize(check)
        var destination: OpaquePointer?
        guard sqlite3_open_v2(backupURL.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw CleanerError.message("No se pudo crear la copia de recuperación.")
        }
        defer { sqlite3_close(destination) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw CleanerError.message("No se pudo iniciar la copia SQLite.") }
        let deadline = Date().addingTimeInterval(5)
        var result: Int32 = SQLITE_OK
        repeat {
            result = sqlite3_backup_step(backup, 128)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.02) }
        } while [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(result) && Date() < deadline
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw CleanerError.message("La copia SQLite no terminó; el historial se conserva.") }
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(source, "ATTACH DATABASE ? AS cleaner_recovery", -1, &attach, nil) == SQLITE_OK else {
            throw CleanerError.message("No se pudo verificar la copia de recuperación.")
        }
        defer { sqlite3_finalize(attach) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = backupURL.path.withCString { sqlite3_bind_text(attach, 1, $0, -1, transient) }
        guard sqlite3_step(attach) == SQLITE_DONE else { throw CleanerError.message("La copia de recuperación no se pudo adjuntar.") }
        do {
            try execute(source, "BEGIN IMMEDIATE")
            try execute(source, "DELETE FROM main.LSQuarantineEvent WHERE LSQuarantineEventIdentifier IN (SELECT LSQuarantineEventIdentifier FROM cleaner_recovery.LSQuarantineEvent)")
            try execute(source, "COMMIT")
        } catch {
            _ = sqlite3_exec(source, "ROLLBACK", nil, nil, nil)
            throw error
        }
        sqlite3_finalize(attach); attach = nil
        _ = sqlite3_exec(source, "DETACH DATABASE cleaner_recovery", nil, nil, nil)
        // Other LaunchServices clients may hold readers; compaction is best-effort after committed deletion.
        _ = sqlite3_exec(source, "VACUUM main", nil, nil, nil)
        return backupURL
    }
    private static func execute(_ connection: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw CleanerError.message("No se pudo vaciar el historial: \(String(cString: sqlite3_errmsg(connection)))")
        }
    }
}
