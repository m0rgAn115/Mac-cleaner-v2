import Foundation

/// Potentially destructive logs stay behind an explicit preference and manual selection.
public enum AdditionalDiscovery {
    public static func discover(home: URL, includeAdvanced: Bool) -> DiscoveryResult {
        guard includeAdvanced else { return DiscoveryResult(targets: [], issues: []) }
        var targets: [ScanTarget] = []
        for name in ["com.apple.LaunchServices.QuarantineEventsV2", "com.apple.LaunchServices.QuarantineEvents"] {
            let url = home.appendingPathComponent("Library/Preferences").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                targets.append(ScanTarget(path: url.path, category: "quarantineLogs", autoselected: false,
                                          detail: "Historial de descargas de LaunchServices. Se conserva una copia de recuperación que también ocupa espacio. Cierra los navegadores antes de limpiar."))
            }
        }
        if home.resolvingSymlinksInPath() == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() {
            let path = "/private/var/db/diagnostics"
            if FileManager.default.fileExists(atPath: path) {
                targets.append(ScanTarget(path: path, category: "diagnosticLogs", autoselected: false,
                                          detail: "Diagnósticos de macOS. Revisión avanzada; puede requerir privilegios y macOS puede regenerarlos."))
            }
        }
        return DiscoveryResult(targets: targets, issues: [])
    }
}

public struct DiskAccess: Identifiable, Sendable {
    public let title: String
    public let status: String
    public var id: String { title }
    public static func inspect(home: URL) -> [DiskAccess] {
        [("Papelera", ".Trash"), ("Mail", "Library/Mail"), ("Cuentas", "Library/Accounts"), ("Contenedores", "Library/Containers")].map { title, path in
            let url = home.appendingPathComponent(path)
            do {
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return DiskAccess(title: title, status: "Accesible")
            } catch {
                let code = (error as NSError).code
                return DiskAccess(title: title, status: [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(code) ? "No existe" : "Acceso restringido por macOS")
            }
        }
    }
}
