import Foundation
import AppKit
import Darwin

/// Providers whose identities and removal APIs are managed by macOS rather than ordinary paths.
public enum AdvancedDiscovery {
    public static func discover(home: URL) -> DiscoveryResult {
        var targets: [ScanTarget] = []
        var issues: [ScanIssue] = []
        let realHome = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if realHome {
            simulators(home: home, targets: &targets, issues: &issues)
            documentVersions(home: home, targets: &targets, issues: &issues)
        }
        return DiscoveryResult(targets: targets, issues: issues)
    }

    private static func detail(_ value: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// File output avoids deadlocks caused by a child filling a pipe before exit.
    private static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-discovery-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw CleanerError.message("No se pudo crear la salida temporal del proveedor.")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CleanerError.message("El proveedor excedió el límite de 20 segundos.")
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: output)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data.prefix(1_024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanerError.message(message.isEmpty ? "El proveedor no está disponible." : message)
        }
        return data
    }

    private static func simulators(home: URL, targets: inout [ScanTarget], issues: inout [ScanIssue]) {
        let root = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        do {
            let data = try command("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = json["devices"] as? [String: [[String: Any]]] else {
                throw CleanerError.message("Formato de dispositivos simctl no reconocido.")
            }
            for devices in groups.values {
                for device in devices {
                    guard let uuid = device["udid"] as? String, UUID(uuidString: uuid) != nil else { continue }
                    let path = root.appendingPathComponent(uuid).path
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    let available = device["isAvailable"] as? Bool ?? ((device["availability"] as? String) == "(available)")
                    targets.append(ScanTarget(path: path, category: "simulators", owner: "com.apple.dt.Xcode",
                                              autoselected: !available, detail: detail(["uuid": uuid, "name": (device["name"] as? String) ?? uuid])))
                }
            }
        } catch { issues.append(ScanIssue(path: root.path, message: "Simuladores: \(error.localizedDescription)")) }
        do {
            let data = try command("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CleanerError.message("Formato de runtimes simctl no reconocido.")
            }
            let runtimes = (json["runtimes"] as? [String: Any]) ?? json
            for (key, value) in runtimes {
                guard let runtime = value as? [String: Any],
                      let uuid = [runtime["identifier"] as? String, runtime["uuid"] as? String, key]
                        .compactMap({ $0 }).first(where: { UUID(uuidString: $0) != nil }) else { continue }
                guard let path = [runtime["diskImagePath"] as? String, runtime["diskImage"] as? String, runtime["path"] as? String]
                        .compactMap({ $0 }).first(where: { $0.hasPrefix("/") && URL(fileURLWithPath: $0).pathExtension.lowercased() == "dmg" }),
                      FileManager.default.fileExists(atPath: path) else {
                    issues.append(ScanIssue(path: uuid, message: "Runtime disponible en simctl sin ruta de imagen verificable; no se ofrece limpieza."))
                    continue
                }
                targets.append(ScanTarget(path: path, category: "simulatorRuntimes", owner: "com.apple.dt.Xcode",
                                          autoselected: false, detail: detail(["uuid": uuid])))
            }
        } catch { issues.append(ScanIssue(path: root.deletingLastPathComponent().path, message: "Runtimes: \(error.localizedDescription)")) }
    }

    private static func documentVersions(home: URL, targets: inout [ScanTarget], issues: inout [ScanIssue]) {
        // Only formats established in the documentation; expand when the remaining UTIs are verified.
        let query = "kMDItemContentTypeTree == 'com.apple.iwork.pages.pages' || kMDItemContentTypeTree == 'com.apple.iwork.numbers.numbers' || kMDItemContentTypeTree == 'com.apple.iwork.keynote.key'"
        do {
            let data = try command("/usr/bin/mdfind", ["-0", "-onlyin", home.path, query])
            let dropbox = dropboxRoots(home: home)
            for part in data.split(separator: 0) {
                let document = URL(fileURLWithPath: String(decoding: part, as: UTF8.self)).standardizedFileURL
                guard document.path.hasPrefix(home.standardizedFileURL.path + "/"),
                      !dropbox.contains(where: { document.path == $0 || document.path.hasPrefix($0 + "/") }) else { continue }
                let versions = (NSFileVersion.otherVersionsOfItem(at: document) ?? []).sorted {
                    ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast)
                }
                let owner = NSWorkspace.shared.urlForApplication(toOpen: document).flatMap { Bundle(url: $0)?.bundleIdentifier }
                for (index, version) in versions.enumerated() {
                    guard FileManager.default.fileExists(atPath: version.url.path) else { continue }
                    let selected: Bool
                    if index > 0, index < versions.count - 1,
                       let date = version.modificationDate, let previous = versions[index - 1].modificationDate {
                        selected = previous.timeIntervalSince(date) < 14_400
                    } else { selected = false }
                    targets.append(ScanTarget(path: version.url.path, category: "documentVersions", owner: owner,
                                              autoselected: selected,
                                              detail: detail(["documentPath": document.path, "versionPath": version.url.path])))
                }
            }
        } catch { issues.append(ScanIssue(path: home.path, message: "Versiones de documentos: \(error.localizedDescription)")) }
    }

    private static func dropboxRoots(home: URL) -> [String] {
        let info = home.appendingPathComponent(".dropbox/info.json")
        var paths = [home.appendingPathComponent("Dropbox").path]
        if let data = try? Data(contentsOf: info),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            paths += accounts.values.compactMap { $0["path"] as? String }.filter { $0.hasPrefix("/") }
        }
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        paths += ((try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.lowercased().hasPrefix("dropbox") }.map(\.path)
        return paths
    }

}
