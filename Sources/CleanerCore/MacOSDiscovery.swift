import AppKit
import Foundation
import Darwin

public struct ScanTarget: Codable, Sendable {
    public let path: String
    public let category: String
    public let owner: String?
    public let autoselected: Bool
    public let detail: String?
    public init(path: String, category: String, owner: String? = nil, autoselected: Bool, detail: String? = nil) {
        self.path = path; self.category = category; self.owner = owner
        self.autoselected = autoselected; self.detail = detail
    }
}

public struct DiscoveryResult: Sendable {
    public let targets: [ScanTarget]
    public let issues: [ScanIssue]
    public init(targets: [ScanTarget], issues: [ScanIssue]) { self.targets = targets; self.issues = issues }
}

public enum MacOSDiscovery {
    public static func discover(home: URL, inventory: ApplicationInventory, includeSystem: Bool) -> DiscoveryResult {
        var discovery = Discovery(home: home, inventory: inventory)
        discovery.scan(includeSystem: includeSystem)
        return DiscoveryResult(targets: discovery.targets, issues: discovery.issues)
    }
}

private struct Discovery {
    let home: URL
    let inventory: ApplicationInventory
    let fm = FileManager.default
    var targets: [ScanTarget] = []
    var issues: [ScanIssue] = []
    var seen: Set<String> = []
    var realHome: Bool {
        home.resolvingSymlinksInPath().standardizedFileURL == fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
    }
    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    func exists(_ value: URL) -> Bool { var info = stat(); return lstat(value.path, &info) == 0 }
    mutating func issue(_ path: URL, _ message: String) {
        issues.append(ScanIssue(path: path.path, message: message))
    }
    mutating func children(_ root: URL) -> [URL] {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            if errno != ENOENT && errno != ENOTDIR { issue(root, String(cString: strerror(errno))) }
            return []
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return [] }
        do {
            return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
        } catch { issue(root, error.localizedDescription); return [] }
    }
    mutating func add(_ target: URL, _ category: String, _ selected: Bool, owner: String? = nil, detail: String? = nil) {
        guard !Task.isCancelled, target.lastPathComponent != ".DS_Store" else { return }
        var info = stat()
        guard lstat(target.path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT != S_IFLNK else { return }
        let path = target.standardizedFileURL.path
        guard seen.insert(path).inserted else { return }
        targets.append(ScanTarget(path: path, category: category, owner: owner ?? (["xcodeArchives", "deviceSupport", "deviceLogs", "xcodeDocumentation", "moduleCaches", "simulatorCaches"].contains(category) ? "com.apple.dt.Xcode" : nil), autoselected: selected, detail: detail))
    }
    mutating func walk(_ root: URL, matching: (URL) -> Bool) -> [URL] {
        guard exists(root) else { return [] }
        var errors: [ScanIssue] = []
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { path, error in
            errors.append(ScanIssue(path: path.path, message: error.localizedDescription)); return true
        }) else { return [] }
        var result: [URL] = []
        while let item = iterator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]), values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
            if matching(item) { result.append(item); if values.isDirectory == true { iterator.skipDescendants() } }
        }
        issues.append(contentsOf: errors)
        return result
    }
    mutating func scan(includeSystem: Bool) {
        if Task.isCancelled { return }
        if realHome {
            let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
            if length > 0 {
                var buffer = [CChar](repeating: 0, count: length)
                _ = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length)
                let root = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                for item in children(root) { add(item, "darwinCaches", true) }
            }
        }
        appCaches()
        backups()
        brokenPreferences()
        brokenAgents(includeSystem: includeSystem)
        developerFiles()
        mailDownloads()
        diskImages()
        trashes()
        if includeSystem && realHome { systemFiles() }
    }
    mutating func appCaches() {
        let fixed: [(String, String?, Bool)] = [
            ("Library/Application Support/Adobe/Common/Media Cache Files", nil, false),
            ("Library/Application Support/Spotify/PersistentCache/Storage", "com.spotify.client", true),
            ("Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video", "com.tencent.tenvideo", false),
            ("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic", "com.tencent.QQMusicMac", false),
            ("Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE", "com.youku.mac", false)
        ]
        for (path, owner, selected) in fixed { add(url(path), "appCaches", selected, owner: owner) }
        for (root, owner) in [
            ("Library/Application Support/Telegram Desktop/tdata/user_data", "com.tdesktop.Telegram"),
            ("Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data", "org.telegram.desktop")
        ] {
            for name in ["cache", "media_cache"] { add(url(root).appendingPathComponent(name), "appCaches", false, owner: owner) }
        }
        let telegram = url("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")
        for first in children(telegram) {
            // Some releases keep accounts directly, others under a versioned data directory.
            let accounts = first.lastPathComponent.hasPrefix("account-") ? [first] : children(first)
            for account in accounts where account.lastPathComponent.hasPrefix("account-") {
                add(account.appendingPathComponent("postbox/media"), "appCaches", false, owner: "ru.keepcoder.Telegram")
            }
        }
        for account in children(url("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9")) {
            add(account.appendingPathComponent("Message/MessageTemp"), "appCaches", false, owner: "com.tencent.xinWeChat")
        }
        let photos = children(url("Library/Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0"))
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let newest = photos.max { accessDate($0) < accessDate($1) }
        for photo in photos where photo != newest { add(photo, "appCaches", true, owner: "com.apple.Photos") }
        var appRoots = [url("Applications")]
        if realHome { appRoots.append(URL(fileURLWithPath: "/Applications")) }
        for root in appRoots {
            let apps = walk(root) { $0.pathExtension == "app" }
            for app in apps {
                guard exists(app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")), let bundle = Bundle(url: app), let id = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? app.deletingPathExtension().lastPathComponent
                // Bundle names are untrusted plist input, never allow them to escape Application Support.
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }
                add(url("Library/Application Support/\(name)/Cache"), "electronCaches", true, owner: id)
                let containers = Set(inventory.containerOwners.filter { $0.value == id }.map(\.key)).union([id])
                for container in containers where !container.contains("/") {
                    add(url("Library/Containers/\(container)/Data/Library/Application Support/\(name)/Cache"), "electronCaches", true, owner: id)
                }
            }
        }
    }
    func accessDate(_ item: URL) -> Date {
        var metadata = stat()
        guard lstat(item.path, &metadata) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(metadata.st_atimespec.tv_sec))
    }
    func plist(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CleanerError.message("El plist no contiene un diccionario.")
        }
        return value
    }
    mutating func backups() {
        var devices: [String: [(URL, Date)]] = [:]
        for backup in children(url("Library/Application Support/MobileSync/Backup")) {
            guard (try? backup.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let info: [String: Any]
            do { info = try plist(backup.appendingPathComponent("Info.plist")) }
            catch {
                let nsError = error as NSError
                // A permission error does not prove that a backup is broken.
                if nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileReadUnknownError].contains(nsError.code) {
                    issue(backup, error.localizedDescription); continue
                }
                add(backup, "iosBackups", true, detail: "Copia de seguridad sin metadatos válidos"); continue
            }
            guard let name = info["Device Name"] as? String, !name.isEmpty else {
                add(backup, "iosBackups", true, detail: "Copia de seguridad sin nombre de dispositivo"); continue
            }
            let key = name + "\u{0}" + (info["Product Type"] as? String ?? "")
            let date = (try? plist(backup.appendingPathComponent("Status.plist"))["Date"] as? Date)
                ?? (info["Last Backup Date"] as? Date) ?? .distantPast
            devices[key, default: []].append((backup, date))
        }
        for entries in devices.values {
            let sorted = entries.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
            for (index, entry) in sorted.enumerated() {
                // Without a date, retain the backup until it can be reviewed.
                add(entry.0, "iosBackups", index > 0 && entry.1 != .distantPast, detail: index == 0 ? "Copia más reciente: conservar por defecto" : "Copia anterior")
            }
        }
    }
    mutating func brokenPreferences() {
        for item in children(url("Library/Preferences")) where item.pathExtension.lowercased() == "plist" && !item.path.contains(".lockfile") {
            do {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUserImmutableKey, .isSystemImmutableKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, values.isUserImmutable != true,
                      values.isSystemImmutable != true, (values.fileSize ?? 0) > 0 else { continue }
                let data = try Data(contentsOf: item)
                do {
                    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                    if !PropertyListSerialization.propertyList(value, isValidFor: .binary) {
                        add(item, "brokenPreferences", true, detail: "Preferencia con estructura inválida")
                    }
                } catch { add(item, "brokenPreferences", true, detail: "Preferencia que no se puede interpretar como plist") }
            } catch { issue(item, error.localizedDescription) }
        }
    }
    mutating func brokenAgents(includeSystem: Bool) {
        var roots = [url("Library/LaunchAgents")]
        if realHome && includeSystem { roots += [URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")] }
        var executableNames: Set<String> = []
        var appRoots = [url("Applications")]
        if realHome { appRoots.append(URL(fileURLWithPath: "/Applications")) }
        for root in appRoots {
            for app in walk(root, matching: { $0.pathExtension == "app" }) {
                if let name = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String { executableNames.insert(name) }
            }
        }
        for root in roots {
            for item in children(root) where item.pathExtension == "plist" {
                do {
                    let info = try plist(item)
                    guard var program = (info["Program"] as? String) ?? (info["ProgramArguments"] as? [String])?.first, !program.isEmpty else {
                        add(item, "brokenAgents", true, detail: "No declara un ejecutable"); continue
                    }
                    if program == "~" { program = home.path }
                    else if program.hasPrefix("~/") { program = home.appendingPathComponent(String(program.dropFirst(2))).path }
                    if !program.hasPrefix("/"), var work = info["WorkingDirectory"] as? String {
                        if work.hasPrefix("~/") { work = home.appendingPathComponent(String(work.dropFirst(2))).path }
                        if work.hasPrefix("/") { program = URL(fileURLWithPath: work).appendingPathComponent(program).path }
                    }
                    // launchd may resolve a relative program via its environment; absence is not established.
                    guard program.hasPrefix("/"), !executableNames.contains(URL(fileURLWithPath: program).lastPathComponent) else { continue }
                    var metadata = stat()
                    if lstat(program, &metadata) != 0, errno == ENOENT || errno == ENOTDIR {
                        add(item, "brokenAgents", true, detail: "Ejecutable inexistente: \(program)")
                    }
                } catch { issue(item, error.localizedDescription) }
            }
        }
    }
    mutating func developerFiles() {
        let xcode = url("Library/Developer/Xcode")
        for archive in walk(xcode.appendingPathComponent("Archives"), matching: { $0.pathExtension == "xcarchive" }) { add(archive, "xcodeArchives", false) }
        for platform in ["iOS", "macOS", "watchOS", "tvOS"] {
            for item in children(xcode.appendingPathComponent("\(platform) DeviceSupport")) { add(item, "deviceSupport", false) }
        }
        add(xcode.appendingPathComponent("iOS Device Logs"), "deviceLogs", true)
        for item in children(xcode.appendingPathComponent("DocumentationCache")) { add(item, "xcodeDocumentation", false) }
        let cache = url("Library/Caches")
        for name in ["org.llvm.clang", "org.llvm.clang.\(home.lastPathComponent)"] {
            add(cache.appendingPathComponent(name).appendingPathComponent("ModuleCache"), "moduleCaches", false)
        }
        add(cache.appendingPathComponent("com.apple.dt.Xcode/ModuleCache"), "moduleCaches", false)
        add(url("Library/Developer/CoreSimulator/Caches"), "simulatorCaches", false)
    }
    mutating func mailDownloads() {
        for root in [url("Library/Mail Downloads"), url("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")] {
            let files = walk(root) { item in
                (try? item.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])).map { $0.isRegularFile == true || $0.isPackage == true } ?? false
            }
            for item in files {
                let dates = try? item.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let unchanged = dates?.creationDate != nil && dates?.creationDate == dates?.contentModificationDate
                add(item, "mailDownloads", unchanged, owner: "com.apple.mail", detail: unchanged ? "Copia sin modificaciones" : "Archivo modificado: revisar")
            }
        }
    }
    mutating func diskImages() {
        var dropboxRoots = [url("Dropbox").standardizedFileURL.path]
        if let data = try? Data(contentsOf: url(".dropbox/info.json")),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            dropboxRoots += accounts.values.compactMap { $0["path"] as? String }.filter { $0.hasPrefix("/") }
        }
        for child in children(url("Library/CloudStorage")) where child.lastPathComponent.hasPrefix("Dropbox") { dropboxRoots.append(child.path) }
        let images: [URL]
        if realHome {
            images = spotlightImages()
        } else {
            images = walk(home) { $0.pathExtension.lowercased() == "dmg" }
        }
        for item in images {
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(home.standardizedFileURL.path + "/"),
                  !dropboxRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            add(item, "diskImages", false, detail: "Imagen de disco: revisar antes de enviar a la Papelera")
        }
    }
    mutating func spotlightImages() -> [URL] {
        // A regular temporary file prevents mdfind from blocking on a full pipe.
        let output = fm.temporaryDirectory.appendingPathComponent("cleanmymaclocal-spotlight-\(UUID().uuidString)")
        guard fm.createFile(atPath: output.path, contents: nil) else { issue(home, "No se pudo preparar la consulta Spotlight."); return [] }
        defer { try? fm.removeItem(at: output) }
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-0", "-onlyin", home.path, "kMDItemContentType == 'com.apple.disk-image-udif'"]
            process.standardOutput = handle; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date() < deadline && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(0.25)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                issue(home, Task.isCancelled ? "Consulta Spotlight cancelada." : "Spotlight superó el límite de 20 segundos; los resultados son parciales.")
                return []
            }
            guard process.terminationStatus == 0 else { issue(home, "Spotlight no pudo completar la búsqueda de imágenes de disco."); return [] }
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 32 * 1_024 * 1_024) ?? Data()
            if data.count == 32 * 1_024 * 1_024 { issue(home, "La búsqueda de imágenes de disco excedió el límite de resultados."); return [] }
            return data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }.map { URL(fileURLWithPath: $0) }
        } catch { issue(home, error.localizedDescription); return [] }
    }
    mutating func trashes() {
        var roots = [url(".Trash"), url("Library/Mobile Documents/com~apple~CloudDocs/.Trash"),
                     url("Library/CloudStorage/iCloud Drive/.Trash"), url("Library/Mobile Documents/.Trash")]
        for container in children(url("Library/Mobile Documents")) { roots.append(container.appendingPathComponent("Documents/.Trash")) }
        if realHome {
            let keys: Set<URLResourceKey> = [.volumeIsBrowsableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey]
            for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [] {
                guard volume.path.hasPrefix("/Volumes/"), let values = try? volume.resourceValues(forKeys: keys),
                      values.volumeIsBrowsable == true, values.volumeIsLocal == true, values.volumeIsReadOnly == false else { continue }
                roots.append(volume.appendingPathComponent(".Trashes/\(getuid())"))
            }
        }
        for root in Set(roots) {
            for item in children(root) { add(item, "trash", false, detail: "Ya está en la Papelera; requiere vaciado definitivo explícito") }
        }
    }
    mutating func systemFiles() {
        for item in children(URL(fileURLWithPath: "/Library/Caches")) { add(item, "systemCaches", true) }
        for item in children(URL(fileURLWithPath: "/System/Library/Caches/com.apple.coresymbolicationd")) { add(item, "systemCaches", true) }
        let local = URL(fileURLWithPath: "/Library/Logs")
        for item in walk(local, matching: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) { addLog(item) }
        let privateRoot = URL(fileURLWithPath: "/private/var/log")
        let names: Set<String> = ["DiagnosticMessages", "cups", "daily.out", "weekly.out", "monthly.out", "system.log", "install.log", "wifi.log", "sck_hfs.log", "fsck_hfs.log", "fsck_apfs.log"]
        for entry in children(privateRoot) {
            let name = entry.lastPathComponent
            guard names.contains(name) || name.range(of: "^(system\\.log\\.[0-9]\\.gz|wifi\\.log\\.[0-9]\\.bz2)$", options: .regularExpression) != nil else { continue }
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for item in walk(entry, matching: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) { addLog(item) }
            } else { addLog(entry) }
        }
        for item in children(URL(fileURLWithPath: "/var/log/asl")) { addLog(item) }
        for item in children(URL(fileURLWithPath: "/Users/Deleted Users")) where item.pathExtension.lowercased() == "dmg" {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { add(item, "deletedUsers", false) }
        }
        let migration = URL(fileURLWithPath: "/Library/SystemMigration/History")
        if let first = children(migration).first(where: { $0.lastPathComponent.hasPrefix("Migration-") }) {
            add(first.appendingPathComponent("QuarantineRoot/private/var/db/dyld"), "systemCaches", false)
        }
    }
    mutating func addLog(_ item: URL) {
        guard fm.isWritableFile(atPath: item.path),
              let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 10_240 else { return }
        add(item, "systemLogs", true)
    }
}
