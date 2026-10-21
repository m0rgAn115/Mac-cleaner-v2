import AppKit
import Foundation

@MainActor
public final class CleaningRunner {
    private var cancelled = false
    public init() {}
    public func cancel() { cancelled = true }
    public static var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    public func run(items: [Candidate], engine: Engine, rules: Rules, simulate: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    forceFailure: Bool = false,
                    progress: (ItemOutcome) -> Void) async -> CleaningReport {
        cancelled = false
        var outcomes: [ItemOutcome] = []
        for item in items {
            if cancelled || Task.isCancelled { break }
            let outcome: ItemOutcome
            do {
                let validation = try await engine.validate(id: item.id, rules: rules, runningBundleIDs: Self.runningBundleIDs)
                if cancelled || Task.isCancelled { break }
                guard validation.valid, let path = validation.path, path == item.path else {
                    throw CleanerError.message(validation.reason ?? "Objetivo no válido.")
                }
                if let owner = item.owner, Self.runningBundleIDs.contains(owner) {
                    throw CleanerError.message("La app propietaria está en ejecución.")
                }
                // shortcut: the native trash API is path-based; a race can remain after Rust's validation.
                // Verify the entry again immediately before calling it; never fall back to deletion.
                var metadata = stat()
                guard lstat(path, &metadata) == 0, UInt64(metadata.st_dev) == item.device,
                      UInt64(metadata.st_ino) == item.inode, metadata.st_mode & S_IFMT != S_IFLNK else {
                    throw CleanerError.message("El objetivo cambió antes del traslado.")
                }
                try await Task.detached(priority: .utility) { try MailDiscovery.validate(candidate: item, home: home) }.value
                if item.cleanup_action == "quarantine" { try SQLiteLogCleaner.validate(path: path) }
                if forceFailure { throw CleanerError.message("Fallo de prueba inducido.") }
                if simulate {
                    outcome = ItemOutcome(id: item.id, path: path, status: "simulated")
                } else {
                    outcome = try await Task.detached(priority: .utility) { try NativeOperations.run(item) }.value
                }
            } catch {
                outcome = ItemOutcome(id: item.id, path: item.path, status: "failed", message: error.localizedDescription)
            }
            outcomes.append(outcome); progress(outcome)
            await Task.yield()
        }
        return CleaningReport(simulated: simulate, cancelled: cancelled || Task.isCancelled, items: outcomes)
    }
}

public struct ApplicationInventory: Sendable {
    public var bundleIDs: Set<String> = []
    public var containerOwners: [String: String] = [:]
    public var cacheOwners: [String: String] = [:]
    public static func discover(home: URL) -> ApplicationInventory {
        var result = ApplicationInventory()
        // Read only bundle metadata, without launching applications or walking their contents.
        let realHome = home.resolvingSymlinksInPath() == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        var ambiguousNames: Set<String> = []
        func register(_ bundle: Bundle, path: URL) {
            guard let id = bundle.bundleIdentifier else { return }
            result.bundleIDs.insert(id)
            for name in [id, bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, path.deletingPathExtension().lastPathComponent].compactMap({ $0 }) where !name.contains("/") && !ambiguousNames.contains(name) {
                if let prior = result.cacheOwners[name], prior != id { ambiguousNames.insert(name); result.cacheOwners.removeValue(forKey: name) }
                else { result.cacheOwners[name] = id }
            }
        }
        if realHome {
            for application in NSWorkspace.shared.runningApplications {
                if let url = application.bundleURL, let bundle = Bundle(url: url) { register(bundle, path: url) }
            }
        }
        let roots = realHome ? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home.appendingPathComponent("Applications")] : [home.appendingPathComponent("Applications")]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
                if url.pathExtension == "app", let bundle = Bundle(url: url) { register(bundle, path: url) }
            }
        }
        if result.bundleIDs.contains("com.google.Chrome") { result.cacheOwners["Google/Chrome"] = "com.google.Chrome" }
        let containers = home.appendingPathComponent("Library/Containers")
        for url in (try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let data = try? Data(contentsOf: metadata),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let id = plist["MCMMetadataIdentifier"] as? String, !id.isEmpty {
                result.containerOwners[url.lastPathComponent] = id
            }
        }
        return result
    }
}
