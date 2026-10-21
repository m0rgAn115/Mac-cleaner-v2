import Foundation
import Darwin
import PrivilegedProtocol

private enum HelperFileError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}
private func posixFailure(_ operation: String) -> HelperFileError {
    .message("\(operation): \(String(cString: strerror(errno)))")
}
private final class OwnedFD {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
}
private struct FileStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let owner: UInt32
    let group: UInt32
    let flags: UInt32
    let links: UInt16
    let size: Int64
    let blocks: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        owner = value.st_uid; group = value.st_gid; flags = value.st_flags; links = value.st_nlink
        size = value.st_size; blocks = value.st_blocks
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    var directory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var regular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var identity: String { "\(device):\(inode)" }
    func sameAfterRename(as other: FileStamp) -> Bool {
        identity == other.identity && mode == other.mode && owner == other.owner && group == other.group && flags == other.flags &&
            links == other.links && size == other.size && blocks == other.blocks &&
            modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
    func guardSafe(owner expectedOwner: uid_t = 0, allowStickyDirectory: Bool = false) throws {
        guard directory || regular else { throw HelperFileError.message("Enlaces y archivos especiales están excluidos.") }
        guard owner == expectedOwner, mode & 0o022 == 0 || (allowStickyDirectory && directory && mode & UInt16(S_ISVTX) != 0) else {
            throw HelperFileError.message("Solo se permite contenido root-owned sin escritura de grupo u otros.")
        }
        guard flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED | UF_APPEND | SF_APPEND) == 0 else {
            throw HelperFileError.message("Elemento protegido por SIP, inmutable o de solo anexado.")
        }
        guard !regular || links == 1 else { throw HelperFileError.message("Los archivos con enlaces duros están excluidos.") }
    }
}
private struct TreeNode {
    let components: [String]
    let stamp: FileStamp
}
private struct TreeSnapshot {
    let nodes: [TreeNode]
    var logicalBytes: UInt64 { nodes.filter { $0.stamp.regular }.reduce(0) { $0 &+ UInt64(max(0, $1.stamp.size)) } }
    var allocatedBytes: UInt64 { nodes.reduce(0) { $0 &+ UInt64(max(0, $1.stamp.blocks)) &* 512 } }
    func matches(_ other: TreeSnapshot, renamed: Bool = false) -> Bool {
        guard nodes.count == other.nodes.count else { return false }
        for (index, pair) in zip(nodes, other.nodes).enumerated() {
            guard pair.0.components == pair.1.components else { return false }
            if index == 0 && renamed {
                guard pair.0.stamp.sameAfterRename(as: pair.1.stamp) else { return false }
            } else if pair.0.stamp != pair.1.stamp { return false }
        }
        return true
    }
}
private final class WalkBudget {
    var remaining = 100_000
    let deadline: Date
    init(seconds: TimeInterval = 20) { deadline = Date().addingTimeInterval(seconds) }
    func consume() throws {
        remaining -= 1
        guard remaining >= 0, Date() < deadline else {
            throw HelperFileError.message("Escaneo parcial: se alcanzó el límite de 100 000 entradas o 20 segundos.")
        }
    }
}
private struct SystemTarget {
    let root: String
    let rootIdentity: String
    let components: [String]
    let ancestors: [String]
    let snapshot: TreeSnapshot
    let item: HelperItem
}

/// Operates exclusively below two fixed roots. Tokens and their snapshots never come from the client.
final class SystemScanner {
    private var scanID: String?
    private var scannedAt = Date.distantPast
    private var targets: [String: SystemTarget] = [:]
    private let roots: [String]
    private let expectedOwner: uid_t
    private let testing: Bool
    private var afterCaptureForTesting: ((URL) throws -> Void)?
    init() { roots = ["/Library/Caches", "/Library/Logs"]; expectedOwner = 0; testing = false }
    private init(testRoots: [String], owner: uid_t) { roots = testRoots; expectedOwner = owner; testing = true }

    func scan(exclusions: HelperExclusions = HelperExclusions()) -> HelperScanResponse {
        let id = UUID().uuidString
        scanID = id; scannedAt = .now; targets = [:]
        var items: [HelperItem] = [], issues: [HelperIssue] = []
        let budget = WalkBudget()
        for root in roots {
            do {
                let fd = try openRoot(root)
                let rootStamp = try descriptorStamp(fd.value)
                for name in try childNames(fd.value) {
                    if root == roots[0], name == HelperConfiguration.quarantineName {
                        do { try reportRetainedCaptures(parent: fd.value, issues: &issues) }
                        catch { issues.append(HelperIssue(path: root + "/" + name, message: error.localizedDescription)) }
                    }
                    if excluded(name) { continue }
                    do {
                        if root == roots[0] {
                            try add(root: root, fd: fd.value, rootIdentity: rootStamp.identity,
                                    components: [name], ancestors: [rootStamp.identity], budget: budget, items: &items)
                        } else {
                            try logs(root: root, parent: fd.value, rootIdentity: rootStamp.identity, components: [name],
                                     ancestors: [rootStamp.identity], budget: budget, items: &items, issues: &issues)
                        }
                    } catch { issues.append(HelperIssue(path: root + "/" + name, message: error.localizedDescription)) }
                    if budget.remaining <= 0 || Date() >= budget.deadline { break }
                }
            } catch { issues.append(HelperIssue(path: root, message: error.localizedDescription)) }
        }
        items = items.filter { item in
            guard let target = targets[item.token], let reason = exclusionReason(target, exclusions: exclusions) else { return true }
            issues.append(HelperIssue(path: item.path, message: reason))
            targets[item.token] = nil
            return false
        }
        return HelperScanResponse(scanID: id, items: items, issues: issues, removalSupported: true)
    }

    func validate(scanID: String?, token: String, exclusions: HelperExclusions = HelperExclusions()) -> HelperValidation {
        do {
            let target = try target(scanID: scanID, token: token)
            if let reason = exclusionReason(target, exclusions: exclusions) { throw HelperFileError.message(reason) }
            let parent = try openParent(target)
            let fresh = try snapshot(parent: parent.value, name: target.components.last!, budget: WalkBudget())
            guard target.snapshot.matches(fresh) else { throw HelperFileError.message("El contenido o la identidad cambió desde el escaneo.") }
            return HelperValidation(token: token, valid: true)
        } catch { return HelperValidation(token: token, valid: false, reason: error.localizedDescription) }
    }

    func remove(scanID: String?, tokens: [String], confirmed: Bool, exclusions: HelperExclusions = HelperExclusions()) -> HelperRemovalResponse {
        guard confirmed else {
            return HelperRemovalResponse(outcomes: tokens.map {
                HelperOutcome(token: $0, path: nil, status: "skipped", message: "Falta confirmación explícita de eliminación definitiva.")
            })
        }
        var outcomes: [HelperOutcome] = []
        let deadline = Date().addingTimeInterval(45)
        for token in tokens {
            if Date() >= deadline {
                outcomes.append(HelperOutcome(token: token, path: targets[token]?.item.path, status: "skipped", message: "Se alcanzó el límite del lote; el elemento no se ha modificado."))
                continue
            }
            do {
                let target = try target(scanID: scanID, token: token)
                if let reason = exclusionReason(target, exclusions: exclusions) { throw HelperFileError.message(reason) }
                outcomes.append(try captureAndRemove(target, token: token, deadline: deadline))
            } catch {
                outcomes.append(HelperOutcome(token: token, path: targets[token]?.item.path, status: "failed", message: error.localizedDescription))
            }
        }
        return HelperRemovalResponse(outcomes: outcomes)
    }

    private func target(scanID: String?, token: String) throws -> SystemTarget {
        guard scanID == self.scanID, Date().timeIntervalSince(scannedAt) < 900,
              let target = targets[token] else { throw HelperFileError.message("Token desconocido, consumido o escaneo vencido. Vuelve a escanear.") }
        return target
    }

    private func exclusionReason(_ target: SystemTarget, exclusions: HelperExclusions) -> String? {
        let root = target.item.path
        for path in exclusions.paths {
            let excluded = URL(fileURLWithPath: path).standardizedFileURL.path
            if root == excluded || root.hasPrefix(excluded == "/" ? "/" : excluded + "/") || excluded.hasPrefix(root + "/") {
                return "El objetivo o uno de sus descendientes está excluido por ruta."
            }
        }
        let names = Set(exclusions.names)
        for node in target.snapshot.nodes {
            let components = (root.split(separator: "/").map(String.init)) + node.components
            if components.contains(where: { names.contains($0) }) {
                return "El árbol contiene un nombre excluido; se conserva completo."
            }
        }
        return nil
    }

    private func excluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.hasPrefix(".") || name == HelperConfiguration.quarantineName || lower.hasPrefix("com.apple.") ||
            lower.hasPrefix("diagnostic") || lower.hasPrefix("crashreport") || lower.hasPrefix("install.log") || lower.hasPrefix("system.log") ||
            ["analytics", "apple", "asl"].contains(lower)
    }

    private func openRoot(_ path: String) throws -> OwnedFD {
        guard roots.contains(path) else { throw HelperFileError.message("Raíz no autorizada.") }
        if testing {
            let fd = OwnedFD(open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
            guard fd.value >= 0 else { throw posixFailure("Abrir fixture") }
            try descriptorStamp(fd.value).guardSafe(owner: expectedOwner)
            try rejectExtendedACL(fd.value)
            return fd
        }
        var fd = OwnedFD(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
        guard fd.value >= 0 else { throw posixFailure("Abrir raíz") }
        for component in path.split(separator: "/").map(String.init) {
            let next = openat(fd.value, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw posixFailure("Abrir \(component)") }
            fd = OwnedFD(next)
            try descriptorStamp(fd.value).guardSafe(owner: expectedOwner, allowStickyDirectory: path == roots[0] && component == "Caches")
            try rejectExtendedACL(fd.value)
        }
        return fd
    }

    private func openParent(_ target: SystemTarget) throws -> OwnedFD {
        var fd = try openRoot(target.root)
        guard try descriptorStamp(fd.value).identity == target.rootIdentity else { throw HelperFileError.message("La raíz fue sustituida.") }
        for (index, component) in target.components.dropLast().enumerated() {
            let next = openat(fd.value, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw posixFailure("Abrir ancestro") }
            fd = OwnedFD(next)
            let stamp = try descriptorStamp(fd.value)
            try stamp.guardSafe(owner: expectedOwner)
            try rejectExtendedACL(fd.value)
            guard index + 1 < target.ancestors.count, stamp.identity == target.ancestors[index + 1] else {
                throw HelperFileError.message("Un directorio ancestro fue sustituido.")
            }
        }
        return fd
    }

    private func rejectExtendedACL(_ fd: Int32) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw posixFailure("Comprobar ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == -1 && errno == EINVAL else {
            throw HelperFileError.message("Las ACL extendidas se excluyen para impedir escrituras fuera de los permisos POSIX.")
        }
    }
    private func verifyEntryACL(parent: Int32, name: String, stamp: FileStamp) throws {
        let value = openat(parent, name, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard value >= 0 else { throw posixFailure("Abrir metadatos ACL") }
        let fd = OwnedFD(value)
        guard try descriptorStamp(fd.value) == stamp else { throw HelperFileError.message("El elemento cambió al comprobar ACL.") }
        try rejectExtendedACL(fd.value)
    }
    private func descriptorStamp(_ fd: Int32) throws -> FileStamp {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixFailure("Leer identidad") }
        return FileStamp(info)
    }
    private func entryStamp(parent: Int32, name: String) throws -> FileStamp {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure("Leer \(name)") }
        return FileStamp(info)
    }
    private func childNames(_ fd: Int32) throws -> [String] {
        let copied = dup(fd)
        guard copied >= 0 else { throw posixFailure("Duplicar descriptor") }
        guard let directory = fdopendir(copied) else { close(copied); throw posixFailure("Listar directorio") }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            if names.count > 100_000 { throw HelperFileError.message("Directorio demasiado grande; se omite por seguridad.") }
            errno = 0
        }
        guard errno == 0 else { throw posixFailure("Listar entradas") }
        return names.sorted()
    }

    private func snapshot(parent: Int32, name: String, budget: WalkBudget) throws -> TreeSnapshot {
        var nodes: [TreeNode] = []
        try walk(parent: parent, name: name, components: [], budget: budget, nodes: &nodes)
        return TreeSnapshot(nodes: nodes)
    }
    private func walk(parent: Int32, name: String, components: [String], budget: WalkBudget, nodes: inout [TreeNode]) throws {
        try budget.consume()
        guard components.count < 64 else { throw HelperFileError.message("Árbol demasiado profundo.") }
        guard !excluded(name) else { throw HelperFileError.message("El árbol contiene una exclusión del sistema.") }
        let stamp = try entryStamp(parent: parent, name: name)
        try stamp.guardSafe(owner: expectedOwner)
        try verifyEntryACL(parent: parent, name: name, stamp: stamp)
        nodes.append(TreeNode(components: components, stamp: stamp))
        if stamp.directory {
            let value = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard value >= 0 else { throw posixFailure("Abrir carpeta") }
            let fd = OwnedFD(value)
            guard try descriptorStamp(value) == stamp else { throw HelperFileError.message("La carpeta cambió mientras se abría.") }
            for child in try childNames(fd.value) {
                try walk(parent: fd.value, name: child, components: components + [child], budget: budget, nodes: &nodes)
            }
            guard try descriptorStamp(value) == stamp else { throw HelperFileError.message("La carpeta cambió durante el escaneo.") }
        }
        guard try entryStamp(parent: parent, name: name) == stamp else { throw HelperFileError.message("El elemento cambió durante el escaneo.") }
    }

    private func add(root: String, fd: Int32, rootIdentity: String, components: [String], ancestors: [String],
                     budget: WalkBudget, items: inout [HelperItem]) throws {
        guard targets.count < 10_000 else { throw HelperFileError.message("Se alcanzó el límite de 10 000 candidatos.") }
        let value = try snapshot(parent: fd, name: components.last!, budget: budget)
        guard value.logicalBytes > 0 else { return }
        let token = UUID().uuidString
        let item = HelperItem(token: token, path: root + "/" + components.joined(separator: "/"),
                              category: root == roots[0] ? "systemCaches" : "systemLogs",
                              logicalBytes: value.logicalBytes, allocatedBytes: value.allocatedBytes)
        targets[token] = SystemTarget(root: root, rootIdentity: rootIdentity, components: components,
                                      ancestors: ancestors, snapshot: value, item: item)
        items.append(item)
    }
    private func logs(root: String, parent: Int32, rootIdentity: String, components: [String], ancestors: [String],
                      budget: WalkBudget, items: inout [HelperItem], issues: inout [HelperIssue]) throws {
        try budget.consume()
        guard components.count < 64, let name = components.last, !excluded(name) else { return }
        let stamp = try entryStamp(parent: parent, name: name)
        try stamp.guardSafe(owner: expectedOwner)
        try verifyEntryACL(parent: parent, name: name, stamp: stamp)
        if stamp.directory {
            let value = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard value >= 0 else { throw posixFailure("Abrir logs") }
            let fd = OwnedFD(value)
            guard try descriptorStamp(value) == stamp else { throw HelperFileError.message("La carpeta de logs cambió.") }
            for child in try childNames(fd.value) where !excluded(child) {
                do {
                    try logs(root: root, parent: fd.value, rootIdentity: rootIdentity, components: components + [child],
                             ancestors: ancestors + [stamp.identity], budget: budget, items: &items, issues: &issues)
                } catch { issues.append(HelperIssue(path: root + "/" + (components + [child]).joined(separator: "/"), message: error.localizedDescription)) }
                if budget.remaining <= 0 || Date() >= budget.deadline { break }
            }
        } else if stamp.size > 10_240 {
            try add(root: root, fd: parent, rootIdentity: rootIdentity, components: components,
                    ancestors: ancestors, budget: budget, items: &items)
        }
    }

    private func reportRetainedCaptures(parent: Int32, issues: inout [HelperIssue]) throws {
        let name = HelperConfiguration.quarantineName
        let stamp = try entryStamp(parent: parent, name: name)
        try stamp.guardSafe(owner: expectedOwner)
        guard stamp.directory, stamp.mode & 0o777 == 0o700 else { throw HelperFileError.message("Cuarentena existente con permisos no válidos; no se recorre.") }
        let value = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard value >= 0 else { throw posixFailure("Revisar cuarentena retenida") }
        let fd = OwnedFD(value)
        guard try descriptorStamp(value).identity == stamp.identity else { throw HelperFileError.message("La cuarentena cambió de identidad.") }
        try rejectExtendedACL(value)
        for capture in try childNames(fd.value) {
            issues.append(HelperIssue(path: roots[0] + "/" + name + "/" + capture,
                                     message: "Captura retenida de una limpieza anterior; se conserva para revisión manual, sin eliminación automática."))
        }
    }

    private func quarantine() throws -> OwnedFD {
        let root = try openRoot(roots[0])
        let name = HelperConfiguration.quarantineName
        if mkdirat(root.value, name, 0o700) != 0 && errno != EEXIST { throw posixFailure("Crear cuarentena") }
        let info = try entryStamp(parent: root.value, name: name)
        guard info.directory, info.owner == expectedOwner, info.mode & 0o777 == 0o700 else {
            throw HelperFileError.message("La cuarentena no tiene propietario root y permisos 0700.")
        }
        try info.guardSafe(owner: expectedOwner)
        let value = openat(root.value, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard value >= 0 else { throw posixFailure("Abrir cuarentena") }
        let fd = OwnedFD(value)
        try rejectExtendedACL(fd.value)
        guard try descriptorStamp(fd.value).identity == info.identity else { throw HelperFileError.message("La cuarentena cambió al abrirse.") }
        return fd
    }

    private func captureAndRemove(_ target: SystemTarget, token: String, deadline: Date) throws -> HelperOutcome {
        let parent = try openParent(target)
        let name = target.components.last!
        let before = try snapshot(parent: parent.value, name: name, budget: WalkBudget(seconds: max(0, min(20, deadline.timeIntervalSinceNow))))
        guard target.snapshot.matches(before) else { throw HelperFileError.message("El objetivo cambió; no se ha movido ni eliminado.") }
        let quarantine = try quarantine()
        guard try descriptorStamp(quarantine.value).device == before.nodes[0].stamp.device else {
            throw HelperFileError.message("No hay cuarentena segura en el mismo volumen; no se ha movido ni eliminado.")
        }
        let capturedName = UUID().uuidString
        guard Date() < deadline else { throw HelperFileError.message("Tiempo del lote agotado antes de la captura; no se modificó el objetivo.") }
        guard renameatx_np(parent.value, name, quarantine.value, capturedName, UInt32(RENAME_EXCL)) == 0 else {
            throw posixFailure("Capturar objetivo")
        }
        targets[token] = nil // A captured token is consumed even when restoration is required.
        let retainedPath = roots[0] + "/" + HelperConfiguration.quarantineName + "/" + capturedName
        var removedCount = 0
        do {
            try afterCaptureForTesting?(URL(fileURLWithPath: retainedPath))
            let captured = try snapshotCaptured(parent: quarantine.value, name: capturedName, budget: WalkBudget(seconds: max(0, min(20, deadline.timeIntervalSinceNow))))
            guard before.matches(captured, renamed: true) else { throw HelperFileError.message("La identidad o contenido capturado no coincide; no se elimina.") }
            let expected = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.components.joined(separator: "/"), $0.stamp) })
            try deleteCaptured(parent: quarantine.value, name: capturedName, components: [], expected: expected, deadline: deadline, removedCount: &removedCount)
            return HelperOutcome(token: token, path: target.item.path, status: "removed", message: "Eliminado definitivamente mediante cuarentena privada del helper.")
        } catch {
            let restored = renameatx_np(quarantine.value, capturedName, parent.value, name, UInt32(RENAME_EXCL)) == 0
            let partial = removedCount > 0 ? " Se eliminaron \(removedCount) entradas antes del fallo." : " No se eliminó ninguna entrada."
            return HelperOutcome(token: token, path: target.item.path, status: "failed",
                                 message: error.localizedDescription + partial + (restored ? " El contenido restante se restauró sin sobrescribir." : " El contenido restante se conserva en cuarentena; requiere revisión manual."),
                                 quarantinePath: restored ? nil : retainedPath)
        }
    }

    private func snapshotCaptured(parent: Int32, name: String, budget: WalkBudget) throws -> TreeSnapshot {
        // UUID capture names are private and deliberately not subject to the public root name exclusions.
        try snapshot(parent: parent, name: name, budget: budget)
    }

    private func deleteCaptured(parent: Int32, name: String, components: [String], expected: [String: FileStamp], deadline: Date, removedCount: inout Int) throws {
        guard Date() < deadline else { throw HelperFileError.message("Tiempo de limpieza agotado; se conserva el contenido restante.") }
        let key = components.joined(separator: "/")
        guard let original = expected[key] else { throw HelperFileError.message("Entrada nueva fuera del snapshot; no se elimina.") }
        let current = try entryStamp(parent: parent, name: name)
        try current.guardSafe(owner: expectedOwner)
        try verifyEntryACL(parent: parent, name: name, stamp: current)
        guard (components.isEmpty ? original.sameAfterRename(as: current) : original == current) else {
            throw HelperFileError.message("Una entrada cambió antes de eliminarse.")
        }
        if current.directory {
            let value = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard value >= 0 else { throw posixFailure("Abrir captura") }
            let fd = OwnedFD(value)
            guard try descriptorStamp(fd.value).identity == current.identity else { throw HelperFileError.message("La carpeta capturada cambió de identidad.") }
            for child in try childNames(fd.value) {
                try deleteCaptured(parent: fd.value, name: child, components: components + [child], expected: expected, deadline: deadline, removedCount: &removedCount)
            }
            let final = try entryStamp(parent: parent, name: name)
            try final.guardSafe(owner: expectedOwner)
            guard final.identity == current.identity, try childNames(fd.value).isEmpty else {
                throw HelperFileError.message("La carpeta contiene datos nuevos; se conserva.")
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posixFailure("Retirar carpeta vacía") }
        } else {
            // In a root-owned 0700 quarantine, unprivileged clients cannot replace these names.
            guard unlinkat(parent, name, 0) == 0 else { throw posixFailure("Retirar archivo capturado") }
        }
        removedCount += 1
    }

    /// Runs only with generated unprivileged fixtures; it never opens the production roots or binds XPC.
    static func selfTest() throws -> String {
        guard geteuid() != 0 else { throw HelperFileError.message("Ejecuta las pruebas como usuario normal, sin sudo.") }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("CleanerHelper-self-test-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let caches = base.appendingPathComponent("Caches"), logs = base.appendingPathComponent("Logs")
        for root in [caches, logs] { try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }
        let scanner = SystemScanner(testRoots: [caches.path, logs.path], owner: getuid())
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw HelperFileError.message("Self-test: " + message) }
        }
        func write(_ path: URL, count: Int = 16_384) throws {
            try Data(repeating: 65, count: count).write(to: path)
            guard chmod(path.path, 0o644) == 0 else { throw posixFailure("Permisos fixture") }
        }
        let clean = caches.appendingPathComponent("fixture-clean")
        try fm.createDirectory(at: clean, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try write(clean.appendingPathComponent("data.bin"))
        let log = logs.appendingPathComponent("fixture.log")
        try write(log)
        try write(logs.appendingPathComponent("small.log"), count: 10_240)
        let linkDirectory = caches.appendingPathComponent("fixture-symlink")
        try fm.createDirectory(at: linkDirectory, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: linkDirectory.appendingPathComponent("link"), withDestinationURL: log)
        let hardDirectory = caches.appendingPathComponent("fixture-hardlinks")
        try fm.createDirectory(at: hardDirectory, withIntermediateDirectories: false)
        try write(hardDirectory.appendingPathComponent("a"))
        try fm.linkItem(at: hardDirectory.appendingPathComponent("a"), to: hardDirectory.appendingPathComponent("b"))
        let writable = caches.appendingPathComponent("fixture-writable")
        try write(writable)
        guard chmod(writable.path, 0o666) == 0 else { throw posixFailure("Permisos fixture inseguro") }
        let diagnostics = caches.appendingPathComponent("fixture-protected")
        try fm.createDirectory(at: diagnostics.appendingPathComponent("DiagnosticReports"), withIntermediateDirectories: true)
        try write(diagnostics.appendingPathComponent("DiagnosticReports/report"))
        let scan = scanner.scan()
        try require(scan.items.count == 2, "solo caché segura y log > 10 KiB deben aparecer")
        let item = try scan.items.first(where: { $0.path == clean.path }).unwrap("Falta caché fixture")
        let logItem = try scan.items.first(where: { $0.path == log.path }).unwrap("Falta log fixture")
        try require(scanner.validate(scanID: scan.scanID, token: item.token).valid, "snapshot original válido")
        try require(!scanner.validate(scanID: scan.scanID, token: UUID().uuidString).valid, "rechazar token ajeno")
        try require(!scanner.validate(scanID: scan.scanID, token: item.token,
                    exclusions: HelperExclusions(paths: [clean.appendingPathComponent("future-child").path])).valid, "exclusión descendiente")
        try require(!scanner.validate(scanID: scan.scanID, token: item.token,
                    exclusions: HelperExclusions(names: ["data.bin"])).valid, "exclusión nombre descendiente")
        let denied = scanner.remove(scanID: scan.scanID, tokens: [item.token], confirmed: false)
        try require(denied.outcomes.first?.status == "skipped" && fm.fileExists(atPath: clean.path), "confirmación obligatoria")
        try write(log, count: 20_000)
        try require(!scanner.validate(scanID: scan.scanID, token: logItem.token).valid, "detectar cambio después del escaneo")
        let removed = scanner.remove(scanID: scan.scanID, tokens: [item.token], confirmed: true)
        try require(removed.outcomes.first?.status == "removed" && !fm.fileExists(atPath: clean.path), "captura y eliminación fixture")
        try require(!scanner.validate(scanID: scan.scanID, token: item.token).valid, "token consumido")
        try write(clean)
        let second = scanner.scan()
        let restoreItem = try second.items.first(where: { $0.path == clean.path }).unwrap("Falta fixture restauración")
        scanner.afterCaptureForTesting = { captured in try write(captured, count: 25_000) }
        let restored = scanner.remove(scanID: second.scanID, tokens: [restoreItem.token], confirmed: true)
        try require(restored.outcomes.first?.status == "failed" && restored.outcomes.first?.quarantinePath == nil,
                    "restauración de captura cambiada sin eliminación")
        try require((try? Data(contentsOf: clean).count) == 25_000, "datos cambiados conservados al restaurar")
        let third = scanner.scan()
        let retainItem = try third.items.first(where: { $0.path == clean.path }).unwrap("Falta fixture cuarentena")
        scanner.afterCaptureForTesting = { captured in
            try write(captured, count: 26_000)
            try write(clean, count: 27_000)
        }
        let retained = scanner.remove(scanID: third.scanID, tokens: [retainItem.token], confirmed: true)
        let retainedOutcome = try retained.outcomes.first.unwrap("Falta resultado cuarentena")
        try require(retainedOutcome.status == "failed" && retainedOutcome.quarantinePath != nil, "conservar captura si restaurar sobrescribiría")
        try require((try? Data(contentsOf: clean).count) == 27_000, "no sobrescribir sustituto original")
        if let path = retainedOutcome.quarantinePath {
            try require(fm.fileExists(atPath: path), "captura permanece revisable")
            let recovered = scanner.scan()
            try require(recovered.issues.contains(where: { $0.path == path }), "reportar cuarentenas retenidas tras reiniciar escaneo")
        }
        var protected = stat()
        protected.st_mode = UInt16(S_IFREG) | 0o644; protected.st_uid = 0; protected.st_nlink = 1
        for flags in [UInt32(SF_RESTRICTED), UInt32(UF_IMMUTABLE), UInt32(SF_IMMUTABLE)] {
            protected.st_flags = flags
            var rejected = false
            do { try FileStamp(protected).guardSafe() } catch { rejected = true }
            try require(rejected, "rechazar flags SIP/inmutables en guardrail de metadatos")
        }
        return "Helper self-test: comprobaciones correctas; solo fixtures temporales del usuario, sin root ni servicio."
    }

}


private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw HelperFileError.message(message) }
        return value
    }
}
