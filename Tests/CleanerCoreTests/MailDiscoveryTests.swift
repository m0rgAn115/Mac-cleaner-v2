import Foundation
import SQLite3
import Testing
@testable import CleanerCore

private struct MailFixture {
    let home: URL
    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
    @discardableResult func file(_ path: String, bytes: Data = Data([1, 2, 3])) throws -> URL {
        let value = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: value.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: value)
        return value
    }
    @discardableResult func plist(_ path: String, _ value: [String: Any]) throws -> URL {
        try file(path, bytes: PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))
    }
    func account(_ name: String, type: String = "IMAPAccount", enabled: Bool = true, offline: Bool = false, confirmed: Bool = true) -> MailAccountMetadata {
        MailAccountMetadata(accountPath: home.appendingPathComponent("Library/Mail/V10/\(name)").path,
                            accountType: type, enabled: enabled, offline: offline, remoteCopyConfirmed: confirmed,
                            trashPath: home.appendingPathComponent("Library/Mail/V10/\(name)/Trash.mbox").path)
    }
}


private func mailCandidate(_ target: ScanTarget) throws -> Candidate {
    var fields: [String: Any] = [
        "id": "mail-test", "category": target.category, "path": target.path,
        "logical_bytes": 3, "allocated_bytes": 3, "autoselected": target.autoselected,
        "device": 0, "inode": 0, "fingerprint": 0,
        "cleanup_action": "trash", "dependency_running": false
    ]
    fields["owner"] = target.owner; fields["detail"] = target.detail
    return try JSONDecoder().decode(Candidate.self, from: JSONSerialization.data(withJSONObject: fields))
}

@Test func mailRequiresVerifiedRemoteAccountsAndGroupsCopies() throws {
    let f = try MailFixture(); defer { f.remove() }
    for name in ["imap", "icloud", "pop", "offline", "disabled", "unconfirmed"] {
        try f.file("Library/Mail/V10/\(name)/Inbox.mbox/Attachments/a/same.pdf")
        try f.file("Library/Mail/V10/\(name)/Trash.mbox/data/deleted.emlx")
    }
    try f.file("Library/Mail/V10/imap/Other.mbox/attachments/b/same.pdf")
    try f.file("Library/Mail/V10/imap/Trash.mbox/data/partial.emlxpart")
    try f.file("Library/Mail/V10/imap/Trash.mbox/data/keep.pdf")
    try f.file("Library/Mail/V10/imap/Trash.mbox/not-data/keep.emlx")
    let metadata = MailDiscoveryMetadata(accounts: [
        f.account("imap"), f.account("icloud", type: "AosImapAccount"),
        f.account("pop", type: "POPAccount"), f.account("offline", offline: true),
        f.account("disabled", enabled: false), f.account("unconfirmed", confirmed: false)
    ])
    let result = MailDiscovery.discover(home: f.home, fixtureMetadata: metadata)
    let attachments = result.targets.filter { $0.category == "mailAttachments" }
    #expect(attachments.count == 3)
    #expect(attachments.contains { $0.path.hasSuffix("/Other.mbox/attachments/b/same.pdf") })
    let groups = try attachments.map { target in
        let detail = try #require(target.detail)
        let json = try #require(JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: String])
        return json["group"]
    }
    #expect(Set(groups).count == 1)
    let trash = result.targets.filter { $0.category == "mailTrash" }
    #expect(trash.count == 3)
    #expect(trash.allSatisfy { ["emlx", "emlxpart"].contains(URL(fileURLWithPath: $0.path).pathExtension) && $0.path.contains("/data/") })
    #expect(result.targets.allSatisfy { $0.owner == "com.apple.mail" && $0.autoselected })
    #expect(result.issues.isEmpty)
}

@Test func mailRejectsSymlinkEscapesAndNeverGuessesAccountType() throws {
    let f = try MailFixture(); defer { f.remove() }
    try f.file("Library/Mail/V10/UnverifiedIMAP/Inbox.mbox/Attachments/keep.pdf")
    #expect(MailDiscovery.discover(home: f.home).targets.isEmpty)
    let outside = try f.file("outside/Inbox.mbox/Attachments/keep.pdf")
    let link = f.home.appendingPathComponent("Library/Mail/V10/linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    let result = MailDiscovery.discover(home: f.home, fixtureMetadata: MailDiscoveryMetadata(accounts: [f.account("linked")]))
    #expect(result.targets.isEmpty)
    #expect(!result.issues.isEmpty)
}

@Test func mailReadsModernAccountsSnapshotWithExplicitOnlineState() throws {
    let f = try MailFixture(); defer { f.remove() }
    let root = "Library/Mail/V10/12345678-1234-1234-1234-123456789012"
    try f.plist("Library/Mail/PersistenceInfo.plist", ["LastUsedVersionDirectoryName": "V10"])
    try f.plist(root + "/.mboxCache.plist", ["takenOffline": "NO"])
    try f.file(root + "/Main.mbox/Attachments/copy.pdf")
    try f.file(root + "/INBOX.mbox/Trash.mbox/data/deleted.emlx")
    let properties = try NSKeyedArchiver.archivedData(withRootObject: ["com.apple.Dataclass.Mail": ["TrashMailboxName": "INBOX/Trash"]], requiringSecureCoding: true)
    let databaseURL = try f.file("Library/Accounts/Accounts4.sqlite", bytes: Data())
    var db: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let schema = """
    CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY,ZACCOUNTTYPE INTEGER,ZPARENTACCOUNT INTEGER,ZIDENTIFIER TEXT,ZDATACLASSPROPERTIES BLOB);
    CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY,ZIDENTIFIER TEXT);
    CREATE TABLE ZDATACLASS (Z_PK INTEGER PRIMARY KEY,ZNAME TEXT);
    CREATE TABLE Z_1ENABLEDDATACLASSES (Z_1ENABLEDACCOUNTS INTEGER,Z_2ENABLEDDATACLASSES INTEGER);
    INSERT INTO ZACCOUNTTYPE VALUES (1,'com.apple.account.IMAP');
    INSERT INTO ZDATACLASS VALUES (1,'com.apple.Dataclass.Mail');
    INSERT INTO Z_1ENABLEDDATACLASSES VALUES (1,1);
    """
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "INSERT INTO ZACCOUNT VALUES (1,1,NULL,'12345678-1234-1234-1234-123456789012',?)", -1, &statement, nil) == SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = properties.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
    #expect(sqlite3_step(statement) == SQLITE_DONE)
    sqlite3_finalize(statement)
    let result = MailDiscovery.discover(home: f.home)
    #expect(result.targets.filter { $0.category == "mailAttachments" }.count == 1)
    #expect(result.targets.filter { $0.category == "mailTrash" }.count == 1)
    let attachmentTarget = try #require(result.targets.first { $0.category == "mailAttachments" })
    let trashTarget = try #require(result.targets.first { $0.category == "mailTrash" })
    let attachment = try mailCandidate(attachmentTarget)
    let trash = try mailCandidate(trashTarget)
    try MailDiscovery.validate(candidate: attachment, home: f.home)
    try MailDiscovery.validate(candidate: trash, home: f.home)
    try f.plist(root + "/.mboxCache.plist", ["takenOffline": "YES"])
    #expect(throws: (any Error).self) { try MailDiscovery.validate(candidate: attachment, home: f.home) }
    #expect(throws: (any Error).self) { try MailDiscovery.validate(candidate: trash, home: f.home) }
    #expect(MailDiscovery.discover(home: f.home).targets.isEmpty)
    try f.plist(root + "/.mboxCache.plist", ["takenOffline": "NO"])
    #expect(sqlite3_exec(db, "DELETE FROM Z_1ENABLEDDATACLASSES", nil, nil, nil) == SQLITE_OK)
    #expect(throws: (any Error).self) { try MailDiscovery.validate(candidate: attachment, home: f.home) }
    try FileManager.default.removeItem(at: f.home.appendingPathComponent(root + "/.mboxCache.plist"))
    #expect(MailDiscovery.discover(home: f.home).targets.isEmpty)
}

@Test func mailRevalidationChecksCurrentDeclarationAndPathMembership() throws {
    let f = try MailFixture(); defer { f.remove() }
    try f.file("Library/Mail/V10/imap/Inbox.mbox/Attachments/copy.pdf")
    try f.file("Library/Mail/V10/imap/Trash.mbox/data/deleted.emlx")
    let metadata = MailDiscoveryMetadata(accounts: [f.account("imap")])
    let config = MailDiscovery.configurationURL(home: f.home)
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(metadata).write(to: config)
    let result = MailDiscovery.discover(home: f.home)
    let target = try #require(result.targets.first { $0.category == "mailAttachments" })
    let candidate = try mailCandidate(target)
    try MailDiscovery.validate(candidate: candidate, home: f.home)
    let unrelated = try f.file("Library/Mail/V10/imap/Inbox.mbox/personal.pdf")
    let forgedTarget = ScanTarget(path: unrelated.path, category: target.category, owner: target.owner,
                                  autoselected: true, detail: target.detail)
    #expect(throws: (any Error).self) { try MailDiscovery.validate(candidate: mailCandidate(forgedTarget), home: f.home) }
    let revoked = MailDiscoveryMetadata(accounts: [f.account("imap", confirmed: false)])
    try JSONEncoder().encode(revoked).write(to: config)
    #expect(throws: (any Error).self) { try MailDiscovery.validate(candidate: candidate, home: f.home) }
    try JSONEncoder().encode(metadata).write(to: config)
    try f.plist("Library/Mail/V10/imap/.mboxCache.plist", ["takenOffline": "YES"])
    #expect(throws: (any Error).self) { try MailDiscovery.validate(candidate: candidate, home: f.home) }
}
