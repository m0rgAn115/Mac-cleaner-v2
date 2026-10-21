import Foundation
import Testing
@testable import CleanerCore

private final class RelatedFixture {
    let home: URL
    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("related-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    @discardableResult func file(_ path: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let item = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: item)
        return item
    }
    @discardableResult func plist(_ path: String, _ dictionary: [String: Any]) throws -> URL {
        try file(path, contents: PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }
    func app(_ name: String, id: String, displayName: String? = nil) throws -> URL {
        try plist("Applications/\(name).app/Contents/Info.plist", ["CFBundleIdentifier": id, "CFBundleName": displayName ?? name, "CFBundlePackageType": "APPL"])
        return home.appendingPathComponent("Applications/\(name).app")
    }
}

@Test func relatedResourcesRespectNamesAndVersions() throws {
    let fixture = try RelatedFixture()
    let app = try fixture.app("Foo", id: "com.fixture.Foo")
    let cache = try fixture.file("Library/Application Support/Foo Cache/file").deletingLastPathComponent()
    let preference = try fixture.file("Library/Preferences/ByHost/com.fixture.Foo.UUID.plist")
    let cookie = try fixture.file("Library/Cookies/com.fixture.Foo.binarycookies")
    let otherVersion = try fixture.file("Library/Application Support/Foo 2/file").deletingLastPathComponent()
    let attachedVersion = try fixture.file("Library/Application Support/Foo2/file").deletingLastPathComponent()
    let otherID = try fixture.file("Library/Preferences/com.fixture.Foo2.plist")
    let result = RelatedFilesDiscovery.resources(for: app, home: fixture.home)
    let paths = Set(result.targets.map(\.path))
    #expect(paths.isSuperset(of: [app.path, cache.path, preference.path, cookie.path]))
    #expect(paths.isDisjoint(with: [otherVersion.path, attachedVersion.path, otherID.path]))
    #expect(result.targets.allSatisfy { !$0.autoselected && $0.owner == "com.fixture.Foo" })
    #expect(result.targets.first { $0.path == app.path }?.category == "applications")
    #expect(result.targets.first { $0.path == cache.path }?.detail?.contains("confianza baja") == true)
}

@Test func relatedLeftoversProtectInstalledAndEmbeddedBundleIDs() throws {
    let fixture = try RelatedFixture()
    _ = try fixture.app("Present", id: "com.fixture.Present")
    try fixture.plist("Applications/Present.app/Contents/Library/LoginItems/Helper.app/Contents/Info.plist", ["CFBundleIdentifier": "com.fixture.SharedHelper"])
    let installed = try fixture.file("Library/Preferences/com.fixture.Present.plist")
    let helper = try fixture.file("Library/Preferences/com.fixture.SharedHelper.plist")
    let removed = try fixture.file("Library/Preferences/com.fixture.Removed.plist")
    let support = try fixture.file("Library/Application Support/Removed Data/file").deletingLastPathComponent()
    try fixture.file("Library/Preferences/com.fixture.helper.plist")
    let generic = try fixture.file("Library/Application Support/Helper/file").deletingLastPathComponent()
    let result = RelatedFilesDiscovery.discover(home: fixture.home, installedBundleIDs: ["com.fixture.Present"], containerOwners: [:])
    let paths = Set(result.targets.filter { $0.category == "leftovers" }.map(\.path))
    #expect(paths.isSuperset(of: [removed.path, support.path]))
    #expect(!paths.contains(installed.path))
    #expect(!paths.contains(helper.path))
    #expect(!paths.contains(generic.path))
    #expect(result.targets.filter { $0.category == "leftovers" }.allSatisfy { !$0.autoselected })
}

@Test func relatedResourcesExcludeSharedVendorAndUnverifiedGroups() throws {
    let fixture = try RelatedFixture()
    let app = try fixture.app("Foo", id: "com.vendor.Foo", displayName: "Vendor")
    _ = try fixture.app("Other", id: "com.vendor.Other")
    let vendor = try fixture.file("Library/Application Support/Vendor/file").deletingLastPathComponent()
    let group = try fixture.file("Library/Group Containers/TEAM.com.vendor.shared/file").deletingLastPathComponent()
    let owned = try fixture.file("Library/Caches/com.vendor.Foo/data").deletingLastPathComponent()
    let result = RelatedFilesDiscovery.resources(for: app, home: fixture.home)
    #expect(result.targets.contains { $0.path == owned.path })
    #expect(!result.targets.contains { $0.path == vendor.path || $0.path == group.path })
}

@Test func relatedLaunchAgentsRequireLabelOrOwnedExecutable() throws {
    let fixture = try RelatedFixture()
    let app = try fixture.app("Foo", id: "com.fixture.Foo")
    let valid = try fixture.plist("Library/LaunchAgents/custom.plist", ["Label": "com.fixture.Foo.agent", "Program": "/missing/helper"])
    let falsePositive = try fixture.plist("Library/LaunchAgents/Foo agent.plist", ["Label": "com.other.agent", "Program": "/other/bin"])
    let plugin = try fixture.plist("Library/Plug-Ins/Foo.plugin/Contents/Info.plist", ["CFBundleIdentifier": "com.other.Plugin"]).deletingLastPathComponent().deletingLastPathComponent()
    let result = RelatedFilesDiscovery.resources(for: app, home: fixture.home)
    #expect(result.targets.contains { $0.path == valid.path })
    #expect(!result.targets.contains { $0.path == falsePositive.path || $0.path == plugin.path })
}

@Test func relatedApplicationTargetsProtectSelfAppleAndExternalRoots() throws {
    let fixture = try RelatedFixture()
    for (name, id) in [("Cleaner", "local.cleanmymac.CleanMyMacLocal"), ("Apple", "com.apple.Example")] {
        let app = try fixture.app(name, id: id)
        #expect(RelatedFilesDiscovery.resources(for: app, home: fixture.home).targets.isEmpty)
    }
    try fixture.plist("Desktop/Foo.app/Contents/Info.plist", ["CFBundleIdentifier": "com.fixture.Foo"])
    #expect(RelatedFilesDiscovery.resources(for: fixture.home.appendingPathComponent("Desktop/Foo.app"), home: fixture.home).targets.isEmpty)
    let app = try fixture.app("Foo", id: "com.fixture.Foo")
    let link = fixture.home.appendingPathComponent("Applications/Alias.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
    #expect(RelatedFilesDiscovery.resources(for: link, home: fixture.home).targets.isEmpty)
}
