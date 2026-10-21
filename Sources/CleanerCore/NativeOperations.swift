import AppKit
import Foundation
import Darwin

// Only macOS-specific removers live here; filesystem plans and identity checks remain in Rust.
enum NativeOperations {
    static func run(_ item: Candidate) throws -> ItemOutcome {
        var current = stat()
        guard lstat(item.path, &current) == 0, UInt64(current.st_dev) == item.device,
              UInt64(current.st_ino) == item.inode, current.st_mode & S_IFMT != S_IFLNK else {
            throw CleanerError.message("El objetivo cambió antes de ejecutar la operación.")
        }
        guard item.cleanup_action != "privileged" else { throw CleanerError.message("Esta operación requiere el helper autorizado.") }
        switch item.cleanup_action {
        case "quarantine":
            let recovery = try SQLiteLogCleaner.clean(path: item.path)
            return ItemOutcome(id: item.id, path: item.path, status: "removed", message: "Historial vaciado con copia de recuperación. Las descargas originales se conservan.", recoveryPath: recovery.path)
        case "emptyTrash":
            try FileManager.default.removeItem(atPath: item.path)
            return ItemOutcome(id: item.id, path: item.path, status: "removed")
        case "simulator":
            let info = try details(item)
            guard let uuid = info["uuid"], UUID(uuidString: uuid) != nil,
                  URL(fileURLWithPath: item.path).lastPathComponent == uuid else {
                throw CleanerError.message("Identidad de simulador no válida.")
            }
            _ = try command("/usr/bin/xcrun", ["simctl", "delete", uuid])
            return ItemOutcome(id: item.id, path: item.path, status: "removed")
        case "runtime":
            let info = try details(item)
            guard let uuid = info["uuid"], UUID(uuidString: uuid) != nil else { throw CleanerError.message("UUID de runtime no válido.") }
            let data = try command("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
            let all = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let runtimes = all["runtimes"] as? [String: Any] ?? all
            let match = runtimes.first { key, value in
                guard let fields = value as? [String: Any] else { return false }
                let identifier = fields["identifier"] as? String ?? fields["uuid"] as? String ?? key
                let path = fields["diskImagePath"] as? String ?? fields["diskImage"] as? String ?? fields["path"] as? String
                return identifier == uuid && path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path } == true
            }
            guard match != nil else { throw CleanerError.message("El runtime cambió; vuelve a escanear.") }
            _ = try command("/usr/bin/xcrun", ["simctl", "runtime", "delete", uuid])
            return ItemOutcome(id: item.id, path: item.path, status: "removed")
        case "version":
            let info = try details(item)
            guard let document = info["documentPath"], let versionPath = info["versionPath"], versionPath == item.path,
                  document.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/"),
                  let version = NSFileVersion.otherVersionsOfItem(at: URL(fileURLWithPath: document))?.first(where: { $0.url.path == versionPath }) else {
                throw CleanerError.message("La versión del documento ya no coincide; vuelve a escanear.")
            }
            try version.remove()
            return ItemOutcome(id: item.id, path: item.path, status: "removed")
        case "agent":
            try verifyBrokenAgent(item.path)
            let data = try Data(contentsOf: URL(fileURLWithPath: item.path))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if let label = plist?["Label"] as? String, !label.isEmpty {
                let domain = item.path.hasPrefix("/Library/LaunchDaemons/") ? "system" : "gui/\(geteuid())"
                // A loaded service must be stopped successfully; an unloaded service needs no bootout.
                if (try? command("/bin/launchctl", ["print", "\(domain)/\(label)"])) != nil {
                    _ = try command("/bin/launchctl", ["bootout", domain, item.path])
                }
            }
            return try trash(item)
        default:
            if item.category == "brokenPreferences" {
                let data = try Data(contentsOf: URL(fileURLWithPath: item.path))
                if (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil {
                    throw CleanerError.message("La preferencia ya es válida; vuelve a escanear.")
                }
            }
            return try trash(item)
        }
    }
    private static func trash(_ item: Candidate) throws -> ItemOutcome {
        var destination: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &destination)
        return ItemOutcome(id: item.id, path: item.path, status: "trashed", trashPath: destination?.path)
    }
    private static func details(_ item: Candidate) throws -> [String: String] {
        guard let raw = item.detail, let data = raw.data(using: .utf8), let info = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CleanerError.message("Faltan los metadatos para esta operación.")
        }
        return info
    }
    private static func verifyBrokenAgent(_ path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        guard var program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first else { return }
        program = (program as NSString).expandingTildeInPath
        if !program.hasPrefix("/"), let working = plist["WorkingDirectory"] as? String {
            program = URL(fileURLWithPath: (working as NSString).expandingTildeInPath).appendingPathComponent(program).path
        }
        guard program.hasPrefix("/") else { throw CleanerError.message("No se pudo resolver el ejecutable del agente.") }
        var metadata = stat()
        if lstat(program, &metadata) == 0 { throw CleanerError.message("El ejecutable del agente existe; se conserva.") }
        guard errno == ENOENT || errno == ENOTDIR else { throw CleanerError.message("Sin permiso para verificar el agente; se conserva.") }
    }
    private static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-operation-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CleanerError.message("No se pudo preparar la operación.") }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CleanerError.message("La operación excedió 30 segundos. Vuelve a escanear para verificar su estado.")
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: output)
        guard process.terminationStatus == 0 else { throw CleanerError.message(String(decoding: data.prefix(2048), as: UTF8.self)) }
        return data
    }
}
