import AppKit
import Foundation
import Testing
@testable import CleanerCore

private final class Fixture: @unchecked Sendable {
    let home: URL
    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    @discardableResult func file(_ path: String, bytes: Int = 64) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }
    func scan(rules: Rules = Rules(), installed: Set<String> = []) async throws -> (Engine, [Candidate]) {
        let engine = try Engine(home: home, rules: rules, installedBundleIDs: installed)
        var result: [Candidate] = []
        for _ in 0..<5000 {
            let batch = try await engine.poll()
            result += batch.items
            if batch.done { return (engine, result.sorted { $0.path < $1.path }) }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CleanerError.message("Scan timed out")
    }
}

@Test func bridgeDecodesCategoriesAndIdentity() async throws {
    let f = try Fixture()
    try f.file("Library/Caches/foo/file")
    try f.file("Library/Containers/com.example.App/Data/Library/Caches/bar/file")
    try f.file("Library/Containers/com.example.App/Data/Documents/personal")
    try f.file("Library/Logs/boundary", bytes: 10240)
    try f.file("Library/Logs/large", bytes: 10241)
    try f.file(".gradle/caches/modules/file")
    let (engine, items) = try await f.scan(installed: ["com.example.App"])
    #expect(items.count == 4)
    #expect(items.allSatisfy { $0.inode > 0 && $0.device > 0 && $0.logical_bytes > 0 })
    #expect(items.first { $0.category == "gradle" }?.autoselected == false)
    #expect(items.first { $0.category == "containerCaches" }?.owner == "com.example.App")
    for item in items {
        let check = try await engine.validate(id: item.id, rules: Rules(), runningBundleIDs: [])
        #expect(check.valid)
        #expect(check.path == item.path)
    }
}

@Test func bridgeRejectsChangedFileAndRunningApplication() async throws {
    let f = try Fixture()
    let url = try f.file("Library/Caches/com.example.App/file")
    let (engine, items) = try await f.scan(installed: ["com.example.App"])
    let item = try #require(items.first)
    let running = try await engine.validate(id: item.id, rules: Rules(), runningBundleIDs: ["com.example.App"])
    #expect(!running.valid)
    try Data("changed".utf8).write(to: url)
    let changed = try await engine.validate(id: item.id, rules: Rules(), runningBundleIDs: [])
    #expect(!changed.valid)
    engine.cancel()
    let cancelled = try await engine.validate(id: item.id, rules: Rules(), runningBundleIDs: [])
    #expect(!cancelled.valid)
}

@Test func storageRoundTripAndMalformedRulesFailClosed() throws {
    let f = try Fixture()
    let storage = Storage(directory: f.home.appendingPathComponent("config"))
    #expect(try storage.loadRules() == Rules())
    var rules = Rules(); rules.paths = [f.home.appendingPathComponent("Library/Caches/foo").path]
    rules.names = ["keep"]; rules.bundle_ids = ["com.example.Keep"]
    try storage.saveRules(rules)
    #expect(try storage.loadRules() == rules)
    #expect(try Storage.bundledRules().version == 1)
    let mode = try FileManager.default.attributesOfItem(atPath: storage.directory.appendingPathComponent("exclusions.json").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    try Data("{broken".utf8).write(to: storage.directory.appendingPathComponent("exclusions.json"))
    #expect(throws: (any Error).self) { try storage.loadRules() }
    var incompatible = Rules(); incompatible.version = 2
    #expect(throws: (any Error).self) { try storage.saveRules(incompatible) }
}

@Test @MainActor func simulationAndForcedFailureNeverMoveFiles() async throws {
    let f = try Fixture()
    let target = try f.file("Library/Caches/foo/file")
    let (engine, items) = try await f.scan()
    let runner = CleaningRunner()
    let report = await runner.run(items: items, engine: engine, rules: Rules(), simulate: true) { _ in }
    #expect(report.items.map(\.status) == ["simulated"])
    #expect(FileManager.default.fileExists(atPath: target.path))
    let failed = await runner.run(items: items, engine: engine, rules: Rules(), simulate: false, forceFailure: true) { _ in }
    #expect(failed.items.map(\.status) == ["failed"])
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test @MainActor func partialFailureAndCancellationPreserveResults() async throws {
    let f = try Fixture()
    let first = try f.file("Library/Caches/a/file")
    try f.file("Library/Caches/b/file")
    let (engine, items) = try await f.scan()
    try Data("changed".utf8).write(to: first)
    let runner = CleaningRunner()
    let report = await runner.run(items: items, engine: engine, rules: Rules(), simulate: true) { _ in }
    #expect(report.items.map(\.status) == ["failed", "simulated"])
    let cancelled = await runner.run(items: items, engine: engine, rules: Rules(), simulate: true) { _ in runner.cancel() }
    #expect(cancelled.cancelled)
    #expect(cancelled.items.count == 1)
    let storage = Storage(directory: f.home.appendingPathComponent("config"))
    let url = try storage.saveReport(report)
    let data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(data?["version"] as? Int == 1)
    #expect((data?["items"] as? [[String: Any]])?.count == 2)
}

@Test @MainActor func realTrashOnlyTouchesFixtureAndCanBeRecovered() async throws {
    let f = try Fixture()
    let target = try f.file("Library/Caches/cleaner-test-\(UUID().uuidString)")
    let (engine, items) = try await f.scan()
    let runner = CleaningRunner()
    let report = await runner.run(items: items, engine: engine, rules: Rules(), simulate: false) { _ in }
    let outcome = try #require(report.items.first)
    #expect(outcome.status == "trashed", "\(outcome.message ?? "")")
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let trash = try #require(outcome.trashPath)
    #expect(FileManager.default.fileExists(atPath: trash))
    // Recover the generated test file immediately, leaving no fixture in the user's Trash.
    try FileManager.default.moveItem(at: URL(fileURLWithPath: trash), to: target)
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func exclusionsRevalidateDescendants() async throws {
    let f = try Fixture()
    let kept = try f.file("Library/Caches/foo/keep")
    let (engine, items) = try await f.scan()
    let item = try #require(items.first)
    var rules = Rules(); rules.paths = [kept.path]
    let checked = try await engine.validate(id: item.id, rules: rules, runningBundleIDs: [])
    #expect(!checked.valid)
    let (_, excluded) = try await f.scan(rules: rules)
    #expect(excluded.first?.selectable == false)
    #expect(excluded.first?.autoselected == false)
}

@Test func cancelledSessionStillDrainsAndRejectsUnknownIDs() async throws {
    let f = try Fixture()
    try f.file("Library/Caches/foo")
    let (engine, _) = try await f.scan()
    let unknown = try await engine.validate(id: "../../outside", rules: Rules(), runningBundleIDs: [])
    #expect(!unknown.valid)
    engine.cancel()
    let batch = try await engine.poll()
    #expect(batch.done && batch.cancelled)
}

@Test func expandedDiscoveryPreservesRecentBackupsAndFindsSourceDownloads() async throws {
    let f = try Fixture()
    let recent = try f.file("Library/Application Support/MobileSync/Backup/new/Info.plist")
    let old = try f.file("Library/Application Support/MobileSync/Backup/old/Info.plist")
    for (url, date) in [(recent, Date()), (old, Date(timeIntervalSince1970: 100))] {
        let info: [String: Any] = ["Device Name": "Fixture iPhone", "Product Type": "iPhone", "Last Backup Date": date]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url)
        try f.file(url.deletingLastPathComponent().path.replacingOccurrences(of: f.home.path + "/", with: "") + "/data", bytes: 1024)
    }
    try f.file("Library/Preferences/com.fixture.broken.plist", bytes: 10)
    try f.file("Library/Developer/Xcode/Archives/2026/Demo.xcarchive/build", bytes: 20)
    let download = try f.file("Downloads/installer.dmg", bytes: 40)
    let safari = try f.file("Library/Safari/Downloads.plist")
    let history: [String: Any] = ["DownloadHistory": [["DownloadEntryPath": download.path, "DownloadEntryProgressBytesSoFar": 40, "DownloadEntryProgressTotalToLoad": 40]]]
    try PropertyListSerialization.data(fromPropertyList: history, format: .binary, options: 0).write(to: safari)
    let inventory = ApplicationInventory()
    let basic = MacOSDiscovery.discover(home: f.home, inventory: inventory, includeSystem: true)
    let related = RelatedFilesDiscovery.discover(home: f.home, installedBundleIDs: [], containerOwners: [:])
    #expect(basic.targets.contains { $0.category == "iosBackups" && $0.path.hasSuffix("/old") && $0.autoselected })
    #expect(basic.targets.contains { $0.category == "iosBackups" && $0.path.hasSuffix("/new") && !$0.autoselected })
    #expect(basic.targets.contains { $0.category == "brokenPreferences" })
    #expect(basic.targets.contains { $0.category == "xcodeArchives" })
    #expect(related.targets.contains { $0.path == download.path && $0.category == "downloads" && !$0.autoselected })
    #expect(basic.targets.allSatisfy { $0.path.hasPrefix(f.home.path + "/") })
    let engine = try Engine(home: f.home, rules: Rules(), targets: basic.targets + related.targets)
    var found: [Candidate] = []
    for _ in 0..<1000 {
        let batch = try await engine.poll(); found += batch.items
        if batch.done { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(found.contains { $0.category == "iosBackups" })
    #expect(found.contains { $0.category == "diskImages" || $0.category == "downloads" })
    #expect(found.allSatisfy { !$0.irreversible || !$0.autoselected })
}
