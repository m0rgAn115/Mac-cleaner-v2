import AppKit
import Darwin
import Foundation
import Security

/// Sources inferred from application history, never from a blanket Downloads-folder scan.
public enum RelatedFilesDiscovery {
    public static func discover(home: URL, installedBundleIDs: Set<String>, containerOwners: [String: String]) -> DiscoveryResult {
        var collector = Collector(home: home.standardizedFileURL.resolvingSymlinksInPath())
        collector.safari()
        collector.chrome()
        collector.slack()
        collector.leftovers(installed: installedBundleIDs, containerOwners: containerOwners)
        return DiscoveryResult(targets: collector.targets, issues: collector.issues)
    }

    public static func resources(for application: URL, home: URL) -> DiscoveryResult {
        var collector = Collector(home: home.standardizedFileURL.resolvingSymlinksInPath())
        collector.applicationResources(application.standardizedFileURL)
        return DiscoveryResult(targets: collector.targets, issues: collector.issues)
    }

    private struct AppIdentity {
        let id: String
        let names: Set<String>
        let path: URL?
        let associated: Set<String>
        let groups: Set<String>
        var identifiers: Set<String> { associated.union([id]) }
    }

    private struct Collector {
        let home: URL
        var targets: [ScanTarget] = []
        var issues: [ScanIssue] = []
        var seen: Set<String> = []
        let fm = FileManager.default

        func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }

        mutating func children(_ root: URL) -> [URL] {
            guard !Task.isCancelled else { return [] }
            do {
                return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
            } catch {
                record(error, at: root)
                return []
            }
        }

        mutating func record(_ error: Error, at source: URL) {
            let ns = error as NSError
            // Missing optional histories are normal; permission/TCC failures must stay visible.
            guard !(ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError)) else { return }
            issues.append(ScanIssue(path: source.path, message: error.localizedDescription))
        }

        mutating func read(_ source: URL, plist: Bool = false) -> Any? {
            guard !Task.isCancelled, contained(source) else { return nil }
            do {
                let data = try Data(contentsOf: source)
                return try plist ? PropertyListSerialization.propertyList(from: data, format: nil) : JSONSerialization.jsonObject(with: data)
            } catch {
                record(error, at: source)
                return nil
            }
        }

        func contained(_ item: URL) -> Bool {
            let prefix = home.path + "/"
            return item.standardizedFileURL.path.hasPrefix(prefix)
                && item.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/")
        }

        mutating func append(_ path: String, category: String, owner: String?, selected: Bool = false, detail: String, allowDirectory: Bool = true) {
            guard !Task.isCancelled, path.hasPrefix("/") else { return }
            let item = URL(fileURLWithPath: path).standardizedFileURL
            guard contained(item), !seen.contains(item.path) else { return }
            do {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { return }
                if values.isDirectory == true {
                    guard allowDirectory else { return }
                } else {
                    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return }
                }
                seen.insert(item.path)
                targets.append(ScanTarget(path: item.path, category: category, owner: owner, autoselected: selected, detail: detail))
            } catch { record(error, at: item) }
        }

        mutating func safari() {
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
            for relative in ["Library/Safari/Downloads.plist", "Library/Containers/com.apple.Safari/Data/Library/Safari/Downloads.plist"] {
                guard let history = read(url(relative), plist: true) as? [String: Any],
                      let entries = history["DownloadHistory"] as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let path = entry["DownloadEntryPath"] as? String else { continue }
                    let received = entry["DownloadEntryProgressBytesSoFar"] as? NSNumber
                    let total = entry["DownloadEntryProgressTotalToLoad"] as? NSNumber
                    let partial = received != nil && total != nil && received != total
                    var item = URL(fileURLWithPath: path)
                    if partial {
                        // Only known Safari .download packages can stand in for a partial file.
                        if item.pathExtension != "download" { item.deleteLastPathComponent() }
                        guard item.pathExtension == "download" else { continue }
                    }
                    append(item.path, category: "downloads", owner: "com.apple.Safari", selected: partial && !running,
                           detail: partial ? "Safari · descarga parcial" : "Safari · historial de descargas", allowDirectory: partial)
                }
            }
        }

        mutating func chrome() {
            let root = url("Library/Application Support/Google/Chrome")
            guard let state = read(root.appendingPathComponent("Local State")) as? [String: Any],
                  let profile = state["profile"] as? [String: Any],
                  let profiles = profile["info_cache"] as? [String: Any] else { return }
            for (directory, info) in profiles.sorted(by: { $0.key < $1.key }) {
                if Task.isCancelled { break }
                guard !directory.isEmpty, directory != ".", directory != "..", !directory.contains("/") else { continue }
                let database = root.appendingPathComponent(directory).appendingPathComponent("History")
                guard contained(database) else { continue }
                do {
                    _ = try database.resourceValues(forKeys: [.isRegularFileKey])
                    let rows = try queryChrome(database)
                    let name = (info as? [String: Any])?["name"] as? String ?? directory
                    for row in rows {
                        guard let path = row["current_path"] as? String else { continue }
                        append(path, category: "downloads", owner: "com.google.Chrome", detail: "Chrome · \(name)", allowDirectory: false)
                    }
                } catch { record(error, at: database) }
            }
        }

        func queryChrome(_ database: URL) throws -> [[String: Any]] {
            let work = fm.temporaryDirectory.appendingPathComponent("CleanMyMacLocal-history-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: work) }
            let output = work.appendingPathComponent("rows.json")
            let errors = work.appendingPathComponent("errors.txt")
            fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let out = try FileHandle(forWritingTo: output)
            let err = try FileHandle(forWritingTo: errors)
            defer { try? out.close(); try? err.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            // A read transaction gives a consistent SQLite/WAL snapshot without modifying Chrome's DB.
            process.arguments = ["-readonly", "-json", "-cmd", ".timeout 1000", database.path,
                                 "BEGIN; SELECT current_path FROM downloads; COMMIT;"]
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw CleanerError.message("El historial de Chrome no respondió a tiempo.")
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CleanerError.message("No se pudo leer el historial de Chrome: \((try? String(contentsOf: errors, encoding: .utf8)) ?? "SQLite")")
            }
            let data = try Data(contentsOf: output)
            return data.isEmpty ? [] : (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? [])
        }

        mutating func slack() {
            for relative in ["Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/storage", "Library/Application Support/Slack/storage"] {
                let root = url(relative)
                for source in [root.appendingPathComponent("slack-downloads"), root.appendingPathComponent("root-state.json")] {
                    guard let object = read(source) else { continue }
                    if source.lastPathComponent == "root-state.json" {
                        guard let dictionary = object as? [String: Any], let downloads = dictionary["downloads"] else { continue }
                        slackRecords(downloads)
                    } else { slackRecords(object) }
                }
            }
        }

        mutating func slackRecords(_ value: Any, depth: Int = 0) {
            guard !Task.isCancelled, depth < 12 else { return }
            if let dictionary = value as? [String: Any] {
                if let path = dictionary["downloadPath"] as? String,
                   let state = dictionary["downloadState"] as? String,
                   let progress = dictionary["progress"] as? NSNumber,
                   let paused = dictionary["isPaused"] as? NSNumber,
                   let start = dictionary["startTime"] as? NSNumber {
                    guard state != "progressing", !paused.boolValue, ["completed", "interrupted"].contains(state) else { return }
                    let timestamp = start.doubleValue
                    // shortcut: ambiguous timestamp units never cause age-based preselection.
                    let old = timestamp >= 946_684_800 && timestamp < Date().timeIntervalSince1970 - 30 * 86_400
                    let incomplete = progress.doubleValue >= 0 && progress.doubleValue < 1
                    append(path, category: "downloads", owner: "com.tinyspeck.slackmacgap", selected: old || incomplete,
                           detail: "Slack · historial de descargas", allowDirectory: false)
                } else {
                    for nested in dictionary.values { slackRecords(nested, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                for nested in array { slackRecords(nested, depth: depth + 1) }
            }
        }

        var realHome: Bool {
            home.resolvingSymlinksInPath() == fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        }

        var applicationRoots: [URL] {
            realHome ? [URL(fileURLWithPath: "/Applications"), url("Applications")] : [url("Applications")]
        }

        func safeApplication(_ application: URL) -> Bool {
            guard application.pathExtension.lowercased() == "app",
                  application.standardizedFileURL.path == application.resolvingSymlinksInPath().path,
                  applicationRoots.contains(where: { application.path.hasPrefix($0.standardizedFileURL.path + "/") }) else { return false }
            var parent = application.deletingLastPathComponent()
            while parent.path != "/" {
                if parent.pathExtension.lowercased() == "app" { return false }
                parent.deleteLastPathComponent()
            }
            var info = stat()
            return lstat(application.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                && info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED) == 0
        }

        mutating func plist(_ source: URL) -> [String: Any]? {
            do {
                return try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any]
            } catch { record(error, at: source); return nil }
        }

        mutating func identity(_ application: URL) -> AppIdentity? {
            guard let info = plist(application.appendingPathComponent("Contents/Info.plist")),
                  let id = info["CFBundleIdentifier"] as? String else { return nil }
            let names = Set([application.deletingPathExtension().lastPathComponent,
                             info["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String,
                             info["CFBundleHelpBookName"] as? String].compactMap { $0 }.filter { !$0.isEmpty })
            var associated: Set<String> = []
            if let iterator = fm.enumerator(at: application.appendingPathComponent("Contents"), includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in false }) {
                while let nested = iterator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    guard (try? nested.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { iterator.skipDescendants(); continue }
                    guard ["app", "appex", "xpc", "framework", "bundle"].contains(nested.pathExtension) else { continue }
                    for suffix in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
                        if let metadata = plist(nested.appendingPathComponent(suffix)), let nestedID = metadata["CFBundleIdentifier"] as? String {
                            associated.insert(nestedID)
                            break
                        }
                    }
                }
            }
            var groups: Set<String> = []
            var code: SecStaticCode?
            if SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess, let code {
                var information: CFDictionary?
                if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                   let signing = information as? [String: Any], let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                   let identifiers = entitlements["com.apple.security.application-groups"] as? [String], !identifiers.isEmpty,
                   SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess {
                    groups = Set(identifiers)
                }
            }
            return AppIdentity(id: id, names: names, path: application, associated: associated, groups: groups)
        }

        mutating func installedApplications() -> [AppIdentity] {
            var result: [AppIdentity] = []
            for root in applicationRoots {
                guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in false }) else { continue }
                while let application = iterator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    guard (try? application.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { iterator.skipDescendants(); continue }
                    if application.pathExtension == "app", let app = identity(application) { result.append(app) }
                }
            }
            return result
        }

        func related(_ first: String, _ second: String) -> Bool {
            let a = normalized(first), b = normalized(second)
            return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
        }

        mutating func leftovers(installed: Set<String>, containerOwners: [String: String]) {
            let applications = installedApplications()
            let protected = installed.union(applications.flatMap { $0.identifiers.union($0.groups) })
            let names = Set(applications.flatMap(\.names).map(normalized))
            var candidateIDs: Set<String> = []
            var containerPaths: [String: [URL]] = [:]
            for file in children(url("Library/Preferences")) where file.pathExtension == "plist" {
                candidateIDs.insert(file.deletingPathExtension().lastPathComponent)
            }
            for container in children(url("Library/Containers")) {
                let id = containerOwners[container.path] ?? containerOwners[container.lastPathComponent] ?? container.lastPathComponent
                candidateIDs.insert(id)
                containerPaths[id, default: []].append(container)
            }
            for id in candidateIDs.sorted() {
                let name = id.split(separator: ".").last.map(String.init) ?? id
                guard plausible(id), !protected.contains(where: { related(id, $0) }), !names.contains(normalized(name)) else { continue }
                let app = AppIdentity(id: id, names: [name], path: nil, associated: [], groups: [])
                gather(app, protected: protected, installedApps: applications, containers: containerPaths[id] ?? [])
            }
        }

        mutating func applicationResources(_ application: URL) {
            guard safeApplication(application), let app = identity(application), plausible(app.id),
                  application != Bundle.main.bundleURL.standardizedFileURL else {
                issues.append(ScanIssue(path: application.path, message: "Aplicación protegida, sin identidad válida o fuera de las carpetas de Aplicaciones permitidas."))
                return
            }
            let installed = installedApplications().filter { $0.path?.resolvingSymlinksInPath().path != application.resolvingSymlinksInPath().path }
            let protected = Set(installed.flatMap { $0.identifiers.union($0.groups) })
            targets.append(ScanTarget(path: application.path, category: "applications", owner: app.id, autoselected: false,
                                      detail: "Aplicación elegida · \(app.id). Mover a la Papelera requiere revisión manual."))
            seen.insert(application.path)
            let containers = children(url("Library/Containers")).filter { container in
                let metadata = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                let owner = plist(metadata)?["MCMMetadataIdentifier"] as? String ?? container.lastPathComponent
                return app.identifiers.contains(owner)
            }
            gather(app, protected: protected, installedApps: installed, containers: containers)
        }

        /// Bundle IDs can occur in names such as group.com.vendor.app; separators prevent app/app2 matches.
        func bundleMatch(_ name: String, _ id: String) -> Bool {
            let pattern = "(^|[._ -])" + NSRegularExpression.escapedPattern(for: id) + "($|[._ -])"
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }

        func wordsMatch(_ resource: URL, name: String) -> Bool {
            let isDirectory = (try? resource.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let candidate = (isDirectory ? resource.lastPathComponent : resource.deletingPathExtension().lastPathComponent).lowercased()
            let appName = name.lowercased()
            let versionPattern = "^" + NSRegularExpression.escapedPattern(for: appName) + "\\s*\\d+"
            guard candidate.range(of: versionPattern, options: .regularExpression) == nil else { return false }
            let wanted = Set(appName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            let generic: Set<String> = ["helper", "shared", "common", "agent", "service", "update", "updater", "framework", "plugin", "support", "cache", "caches", "data", "logs", "preferences", "application", "applications", "default", "system", "library", "container", "containers"]
            guard !wanted.isSubset(of: generic) else { return false }
            let separators = isDirectory ? CharacterSet.alphanumerics.inverted : CharacterSet.whitespacesAndNewlines
            let actual = Set(candidate.components(separatedBy: separators).filter { !$0.isEmpty })
            return !wanted.isEmpty && wanted.isSubset(of: actual)
        }

        mutating func gather(_ app: AppIdentity, protected: Set<String>, installedApps: [AppIdentity], containers: [URL]) {
            let description = "Posible recurso · \(app.id) · revisión manual"
            for container in containers where contained(container) {
                guard !protected.contains(where: { bundleMatch(container.lastPathComponent, $0) }) else { continue }
                append(container.path, category: "leftovers", owner: app.id, detail: description + " · confianza alta: propietario del contenedor")
            }
            let roots = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost", "Library/Logs", "Library/Logs/DiagnosticReports", "Library/Application Support/CrashReporter", "Library/Saved Application State", "Library/Cookies", "Library/LaunchAgents", "Library/LaunchDaemons", "Library/Internet Plug-Ins", "Library/Plug-Ins", "Library/PDF Services", "Library/Help", "Library/Application Scripts", "Library/Caches/TemporaryItems"]
            let structural = Set((roots + ["Library/Containers", "Library/Group Containers", "Library/Keychains", "Library/Accounts", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Photos", "Library/CloudStorage", "Library/Mobile Documents", "Library/Developer", "Library/Fonts"]).map { url($0).path })
            let vendor = app.id.split(separator: ".").dropLast().joined(separator: ".")
            let sharedVendor = protected.contains { $0.hasPrefix(vendor + ".") }
            for root in roots {
                for resource in children(url(root)) {
                    guard !structural.contains(resource.path), contained(resource),
                          !resource.lastPathComponent.lowercased().hasPrefix("com.apple."),
                          !resource.lastPathComponent.lowercased().hasPrefix("group.com.apple."),
                          !seen.contains(where: { resource.path.hasPrefix($0 + "/") }),
                          !protected.contains(where: { bundleMatch(resource.lastPathComponent, $0) }),
                          !installedApps.contains(where: { installed in installed.names.contains { wordsMatch(resource, name: $0) } }) else { continue }
                    var reason: String?
                    if app.identifiers.contains(where: { bundleMatch(resource.lastPathComponent, $0) }) {
                        reason = "confianza alta: bundle ID delimitado en el nombre"
                    } else if app.names.contains(where: { wordsMatch(resource, name: $0) }) {
                        reason = "confianza baja: coincidencia de palabras del nombre; comprueba su contenido"
                    }
                    if root == "Library/Application Scripts", !app.identifiers.contains(resource.lastPathComponent) { continue }
                    if sharedVendor {
                        let vendorName = vendor.split(separator: ".").last.map(String.init) ?? vendor
                        if normalized(resource.deletingPathExtension().lastPathComponent) == normalized(vendorName) { continue }
                    }
                    let launchFile = root == "Library/LaunchAgents" || root == "Library/LaunchDaemons"
                    if launchFile {
                        guard let info = plist(resource) else { continue }
                        let label = info["Label"] as? String ?? ""
                        let program = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first ?? ""
                        let programOwned = app.path.map { program.hasPrefix($0.path + "/") } ?? false
                        guard programOwned || app.identifiers.contains(where: { related(label, $0) }) else { continue }
                        guard !protected.contains(where: { related(label, $0) }) else { continue }
                        reason = "confianza alta: Label o ejecutable vinculado a la aplicación"
                    } else if ["plugin", "bundle", "help", "appex", "xpc"].contains(resource.pathExtension) {
                        for suffix in ["Contents/Info.plist", "Info.plist"] {
                            if let id = plist(resource.appendingPathComponent(suffix))?["CFBundleIdentifier"] as? String {
                                guard !protected.contains(where: { related(id, $0) }), app.identifiers.contains(where: { related(id, $0) }) else { reason = nil; break }
                                reason = "confianza alta: CFBundleIdentifier del recurso"
                                break
                            }
                        }
                    }
                    if let reason { append(resource.path, category: "leftovers", owner: app.id, detail: description + " · " + reason) }
                }
            }
            // A group is included only through verified entitlements, never through a vendor/name guess.
            for group in app.groups where !group.contains("/") && group != "." && group != ".."
                && !group.lowercased().hasPrefix("group.com.apple.") && !group.lowercased().hasPrefix("com.apple.")
                && !protected.contains(where: { related(group, $0) }) {
                append(url("Library/Group Containers").appendingPathComponent(group).path, category: "leftovers", owner: app.id,
                       detail: description + " · confianza alta: grupo declarado en firma; sin otro propietario instalado conocido")
            }
        }

        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        }

        func plausible(_ id: String) -> Bool {
            let parts = id.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3, !id.lowercased().hasPrefix("com.apple."), !id.lowercased().hasPrefix("group.com.apple."),
                  !id.lowercased().hasPrefix("com.macpaw.cleanmymac"), !id.lowercased().hasPrefix("com.cleanmymaclocal"),
                  id.lowercased() != "local.cleanmymac.cleanmymaclocal" else { return false }
            return parts.allSatisfy { part in
                !part.isEmpty && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            }
        }
    }
}
