import Foundation
import Testing
import SQLite3
@testable import CleanerCore

@Test func quarantineHistoryHasConsistentRecoveryAndUnknownSchemasStayIntact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("history.sqlite").path
    var connection: OpaquePointer?
    #expect(sqlite3_open(path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "CREATE TABLE LSQuarantineEvent (LSQuarantineEventIdentifier TEXT PRIMARY KEY, data TEXT); INSERT INTO LSQuarantineEvent VALUES ('fixture','retained backup');", nil, nil, nil) == SQLITE_OK)
    try SQLiteLogCleaner.validate(path: path)
    let backup = try SQLiteLogCleaner.clean(path: path, recoveryDirectory: root.appendingPathComponent("Recovery"))
    func count(_ path: String) -> Int32 {
        var db: OpaquePointer?; var statement: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM LSQuarantineEvent", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(statement, 0)
    }
    #expect(count(path) == 0); #expect(count(backup.path) == 1)
    let unknown = root.appendingPathComponent("unknown.sqlite").path
    var other: OpaquePointer?; #expect(sqlite3_open(unknown, &other) == SQLITE_OK)
    sqlite3_close(other)
    #expect(throws: (any Error).self) { try SQLiteLogCleaner.validate(path: unknown) }
    #expect(throws: (any Error).self) { try SQLiteLogCleaner.clean(path: unknown, recoveryDirectory: root.appendingPathComponent("Recovery")) }
}
