import Foundation
import PrivilegedProtocol

public enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches, containerCaches, userLogs, containerLogs, gradle, derivedData
    case darwinCaches, electronCaches, appCaches, systemCaches, systemLogs
    case iosBackups, brokenPreferences, brokenAgents, mailDownloads, mailAttachments
    case diskImages, downloads, leftovers, xcodeArchives, deviceSupport, moduleCaches
    case xcodeDocumentation, simulatorCaches, deviceLogs, trash, deletedUsers
    case simulators, simulatorRuntimes, documentVersions, applications, mailTrash, quarantineLogs, diagnosticLogs
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .userCaches: "Cachés de usuario"
        case .containerCaches: "Cachés de contenedores"
        case .userLogs: "Logs de usuario"
        case .containerLogs: "Logs de contenedores"
        case .gradle: "Gradle"
        case .derivedData: "DerivedData"
        case .darwinCaches: "Cachés Darwin"
        case .electronCaches: "Apps Electron"
        case .appCaches: "Cachés de aplicaciones"
        case .systemCaches: "Cachés del sistema"
        case .systemLogs: "Logs del sistema"
        case .iosBackups: "Copias de iPhone y iPad"
        case .brokenPreferences: "Preferencias dañadas"
        case .brokenAgents: "Agentes rotos"
        case .mailDownloads: "Descargas de Mail"
        case .mailAttachments: "Adjuntos de Mail"
        case .diskImages: "Imágenes de disco"
        case .downloads: "Descargas por aplicación"
        case .leftovers: "Restos de aplicaciones"
        case .xcodeArchives: "Archivos de Xcode"
        case .deviceSupport: "Soporte de dispositivos"
        case .moduleCaches: "Módulos de Xcode"
        case .xcodeDocumentation: "Documentación de Xcode"
        case .simulatorCaches: "Cachés de simuladores"
        case .deviceLogs: "Logs de dispositivos"
        case .trash: "Papeleras"
        case .deletedUsers: "Usuarios eliminados"
        case .simulators: "Simuladores"
        case .simulatorRuntimes: "Runtimes de simulación"
        case .documentVersions: "Versiones de documentos"
        case .applications: "Desinstalar aplicaciones"
        case .mailTrash: "Papelera de Mail"
        case .quarantineLogs: "Historial de cuarentena"
        case .diagnosticLogs: "Diagnósticos del sistema"
        }
    }
    public var section: String {
        switch self {
        case .mailDownloads, .mailAttachments, .mailTrash: "Correo"
        case .diskImages, .downloads, .trash, .deletedUsers, .documentVersions: "Archivos y papeleras"
        case .leftovers, .brokenAgents, .applications: "Aplicaciones"
        case .gradle, .derivedData, .xcodeArchives, .deviceSupport, .moduleCaches, .xcodeDocumentation, .simulatorCaches, .deviceLogs, .simulators, .simulatorRuntimes: "Desarrollo"
        default: "Basura del sistema"
        }
    }
    public var icon: String {
        switch self {
        case .userCaches, .containerCaches: "internaldrive"
        case .userLogs, .containerLogs: "doc.text"
        case .gradle, .derivedData, .xcodeArchives, .deviceSupport, .moduleCaches, .xcodeDocumentation, .simulatorCaches, .deviceLogs, .simulators, .simulatorRuntimes: "hammer"
        case .darwinCaches, .electronCaches, .appCaches, .systemCaches: "internaldrive"
        case .systemLogs, .brokenPreferences, .documentVersions, .quarantineLogs, .diagnosticLogs: "doc.text"
        case .iosBackups: "iphone"
        case .brokenAgents: "gearshape"
        case .mailDownloads, .mailAttachments, .mailTrash: "envelope"
        case .diskImages: "opticaldiscdrive"
        case .downloads: "arrow.down.circle"
        case .leftovers, .applications: "shippingbox"
        case .trash: "trash"
        case .deletedUsers: "person.crop.circle.badge.minus"
        }
    }
}

public struct Rules: Codable, Sendable, Equatable {
    public var version = 1
    public var paths: [String] = []
    public var names: [String] = []
    public var bundle_ids: [String] = []
    public init() {}
    public func validate() throws {
        guard version == 1, paths.allSatisfy({ $0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw CleanerError.message("Formato de exclusiones incompatible o rutas no válidas.")
        }
    }
    public func merging(_ other: Rules) throws -> Rules {
        try validate(); try other.validate()
        var result = self
        result.paths = Array(Set(paths + other.paths)).sorted()
        result.names = Array(Set(names + other.names)).sorted()
        result.bundle_ids = Array(Set(bundle_ids + other.bundle_ids)).sorted()
        return result
    }
}

public struct Candidate: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let category: String
    public let path: String
    public let logical_bytes: UInt64
    public let allocated_bytes: UInt64
    public let autoselected: Bool
    public let owner: String?
    public let blocked_reason: String?
    public let device: UInt64
    public let inode: UInt64
    public let fingerprint: UInt64
    public let cleanup_action: String
    public let detail: String?
    public let dependency_running: Bool
    public var irreversible: Bool { ["emptyTrash", "simulator", "runtime", "version", "quarantine", "privileged"].contains(cleanup_action) }
    public var name: String {
        if let detail, let data = detail.data(using: .utf8), let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String], let name = fields["name"] { return name }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    public var attachmentGroup: String? {
        guard category == "mailAttachments", let detail, let data = detail.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return fields["group"]
    }
    public var selectable: Bool { blocked_reason == nil }
    public init(helperItem: HelperItem, owner: String? = nil, runningBundleIDs: Set<String> = []) {
        id = "helper:" + helperItem.token; category = helperItem.category; path = helperItem.path
        logical_bytes = helperItem.logicalBytes; allocated_bytes = helperItem.allocatedBytes
        autoselected = false; self.owner = owner; blocked_reason = helperItem.blockedReason
        device = 0; inode = 0; fingerprint = 0; cleanup_action = "privileged"
        detail = "Operación del sistema autorizada: eliminación definitiva mediante helper."
        dependency_running = owner.map { runningBundleIDs.contains($0) } ?? false
    }
}
public struct ScanIssue: Codable, Sendable {
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}
public struct ScanBatch: Decodable, Sendable {
    public let version: Int
    public let items: [Candidate]
    public let errors: [ScanIssue]
    public let done: Bool
    public let cancelled: Bool
    public let visited: UInt64
}
public struct Validation: Decodable, Sendable {
    public let version: Int
    public let valid: Bool
    public let reason: String?
    public let path: String?
}
public enum CleanerError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
public struct ItemOutcome: Codable, Sendable {
    public let id: String
    public let path: String
    public let status: String
    public let message: String?
    public let trashPath: String?
    public let recoveryPath: String?
    public init(id: String, path: String, status: String, message: String? = nil, trashPath: String? = nil, recoveryPath: String? = nil) {
        self.id = id; self.path = path; self.status = status; self.message = message; self.trashPath = trashPath; self.recoveryPath = recoveryPath
    }
}
public struct CleaningReport: Codable, Sendable {
    public let version: Int
    public let date: Date
    public let simulated: Bool
    public let cancelled: Bool
    public let items: [ItemOutcome]
    public init(simulated: Bool, cancelled: Bool, items: [ItemOutcome]) {
        version = 1; date = .now; self.simulated = simulated; self.cancelled = cancelled; self.items = items
    }
}
public func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
