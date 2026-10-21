import Foundation
import CoreFoundation
import SQLite3

/// An explicit local declaration is required when macOS does not expose verifiable Mail metadata.
public struct MailAccountMetadata: Codable, Sendable {
    public let accountPath: String
    public let accountType: String
    public let enabled: Bool
    public let offline: Bool
    public let remoteCopyConfirmed: Bool
    public let trashPath: String?
    public init(accountPath: String, accountType: String, enabled: Bool, offline: Bool,
                remoteCopyConfirmed: Bool, trashPath: String? = nil) {
        self.accountPath = accountPath; self.accountType = accountType
        self.enabled = enabled; self.offline = offline; self.remoteCopyConfirmed = remoteCopyConfirmed
        self.trashPath = trashPath
    }
}

public struct MailDiscoveryMetadata: Codable, Sendable {
    public let version: Int
    public let accounts: [MailAccountMetadata]
    public init(version: Int = 1, accounts: [MailAccountMetadata]) { self.version = version; self.accounts = accounts }
}

public enum MailDiscovery {
    public static func configurationURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/CleanMyMacLocal/mail-accounts.json")
    }
    public static func discover(home: URL) -> DiscoveryResult { discover(home: home, fixtureMetadata: nil) }
    /// Re-read account state before both simulation and cleanup, without enumerating attachment files.
    public static func validate(candidate: Candidate, home: URL) throws {
        guard ["mailAttachments", "mailTrash"].contains(candidate.category) else { return }
        var scanner = MailScanner(home: home.resolvingSymlinksInPath().standardizedFileURL)
        try scanner.validate(candidate)
    }
    /// Metadata injection is only accepted for isolated fixture homes, never for the actual account.
    public static func discover(home: URL, fixtureMetadata: MailDiscoveryMetadata?) -> DiscoveryResult {
        var scanner = MailScanner(home: home.resolvingSymlinksInPath().standardizedFileURL)
        scanner.scan(fixtureMetadata: fixtureMetadata)
        return DiscoveryResult(targets: scanner.targets, issues: scanner.issues)
    }
}

private struct VerifiedMailAccount {
    let root: URL
    let trash: URL?
    let declared: Bool
}

private struct MailScanner {
    let home: URL
    let fm = FileManager.default
    var targets: [ScanTarget] = []
    var issues: [ScanIssue] = []
    var seen: Set<String> = []
    var mailRoot: URL { home.appendingPathComponent("Library/Mail") }
    var realHome: Bool { home == fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL }
    mutating func issue(_ path: URL, _ message: String) { issues.append(ScanIssue(path: path.path, message: message)) }
    func dictionary(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        guard data.count <= 10 * 1_024 * 1_024,
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CleanerError.message("Metadatos de Mail incompatibles.")
        }
        return value
    }
    func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    func contained(_ path: URL, in root: URL) -> Bool {
        let normalized = path.standardizedFileURL
        guard normalized.path.hasPrefix(root.standardizedFileURL.path + "/"),
              normalized.resolvingSymlinksInPath().path == normalized.path else { return false }
        return true
    }
    func directory(_ path: URL) -> Bool {
        guard let values = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    mutating func verifiedAccounts(fixtureMetadata: MailDiscoveryMetadata?) -> [VerifiedMailAccount] {
        if Task.isCancelled { return [] }
        var accounts: [VerifiedMailAccount] = []
        if let fixtureMetadata {
            guard !realHome else { issue(mailRoot, "Los metadatos de prueba no se aceptan en la carpeta personal real."); return [] }
            accounts = declaredAccounts(fixtureMetadata)
        } else {
            do { accounts = try databaseAccounts() }
            catch { issue(mailRoot, "No se pudieron verificar las cuentas de Mail: \(error.localizedDescription)") }
            let config = MailDiscovery.configurationURL(home: home)
            do {
                let data = try Data(contentsOf: config)
                guard data.count <= 1_024 * 1_024 else { throw CleanerError.message("La configuración de Mail es demasiado grande.") }
                accounts += declaredAccounts(try JSONDecoder().decode(MailDiscoveryMetadata.self, from: data))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
            catch { issue(config, "No se pudo leer la selección explícita de cuentas: \(error.localizedDescription)") }
        }
        return accounts
    }
    mutating func scan(fixtureMetadata: MailDiscoveryMetadata?) {
        let accounts = verifiedAccounts(fixtureMetadata: fixtureMetadata)
        var unique: [String: VerifiedMailAccount] = [:]
        for account in accounts {
            if unique[account.root.path] == nil || (unique[account.root.path]?.trash == nil && account.trash != nil) { unique[account.root.path] = account }
        }
        for account in unique.values.sorted(by: { $0.root.path < $1.root.path }) { scanAccount(account) }
        if unique.isEmpty {
            issue(mailRoot, "Adjuntos y mensajes en Papelera omitidos: falta confirmar una cuenta IMAP/iCloud habilitada y online. Puedes declarar cuentas en mail-accounts.json; no se infiere una copia remota por el nombre de una carpeta.")
        }
    }
    mutating func validate(_ candidate: Candidate) throws {
        guard !Task.isCancelled, candidate.owner == "com.apple.mail", let detail = candidate.detail,
              let fields = try JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: String],
              let accountPath = fields["mailAccountPath"], let source = fields["mailSource"],
              ["accountsDatabase", "userDeclaration"].contains(source) else {
            throw CleanerError.message("Falta la evidencia de cuenta de Mail; vuelve a escanear.")
        }
        let accounts = verifiedAccounts(fixtureMetadata: nil)
        guard let account = accounts.first(where: {
            $0.root.standardizedFileURL.path == URL(fileURLWithPath: accountPath).standardizedFileURL.path &&
                $0.declared == (source == "userDeclaration")
        }) else {
            throw CleanerError.message("La cuenta de Mail ya no está verificada como IMAP/iCloud habilitada y online, o se retiró la confirmación de copia remota.")
        }
        let path = URL(fileURLWithPath: candidate.path).standardizedFileURL
        guard contained(path, in: account.root),
              let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true || values.isPackage == true else {
            throw CleanerError.message("El objetivo ya no pertenece a la cuenta de Mail verificada.")
        }
        func hasAncestor(named name: String, inside root: URL) -> Bool {
            var parent = path.deletingLastPathComponent()
            while contained(parent, in: root) {
                if parent.lastPathComponent.lowercased() == name { return true }
                parent.deleteLastPathComponent()
            }
            return false
        }
        let relativeParts = path.path.dropFirst(account.root.path.count + 1).split(separator: "/")
        guard !relativeParts.contains(where: { $0.hasPrefix(".") }) else {
            throw CleanerError.message("El objetivo de Mail está dentro de una ruta oculta.")
        }
        if candidate.category == "mailAttachments" {
            guard hasAncestor(named: "attachments", inside: account.root),
                  account.trash.map({ !contained(path, in: $0) }) ?? true else {
                throw CleanerError.message("El objetivo ya no es un adjunto fuera de la Papelera de Mail.")
            }
        } else {
            guard let trash = account.trash, contained(path, in: trash),
                  ["emlx", "emlxpart"].contains(path.pathExtension.lowercased()),
                  hasAncestor(named: "data", inside: trash) else {
                throw CleanerError.message("El objetivo ya no está en la Papelera verificada de Mail.")
            }
        }
    }
    mutating func declaredAccounts(_ metadata: MailDiscoveryMetadata) -> [VerifiedMailAccount] {
        guard metadata.version == 1 else { issue(mailRoot, "Versión de configuración de Mail incompatible."); return [] }
        var result: [VerifiedMailAccount] = []
        for account in metadata.accounts {
            guard ["IMAPAccount", "AosImapAccount"].contains(account.accountType), account.enabled,
                  !account.offline, account.remoteCopyConfirmed else { continue }
            let root = URL(fileURLWithPath: account.accountPath)
            let relativeParts = root.standardizedFileURL.path.dropFirst(mailRoot.path.count + 1).split(separator: "/")
            guard contained(root, in: mailRoot), directory(root), relativeParts.count == 2,
                  relativeParts.first.map({ String($0).range(of: "^V[0-9]+$", options: .regularExpression) != nil }) == true else {
                issue(mailRoot, "Se rechazó una ruta de cuenta fuera de Mail o con enlaces simbólicos."); continue
            }
            // An observed offline flag overrides an older user declaration.
            if let cache = try? dictionary(root.appendingPathComponent(".mboxCache.plist")),
               boolean(cache["takenOffline"]) == true || (cache["takenOffline"] as? String)?.caseInsensitiveCompare("YES") == .orderedSame { continue }
            var trash: URL?
            if let path = account.trashPath {
                let value = URL(fileURLWithPath: path)
                if contained(value, in: root), directory(value), value.pathExtension.lowercased() == "mbox" { trash = value }
                else { issue(root, "Se rechazó la ruta de Papelera declarada; debe ser un buzón dentro de la cuenta.") }
            }
            result.append(VerifiedMailAccount(root: root, trash: trash, declared: true))
        }
        return result
    }
    mutating func databaseAccounts() throws -> [VerifiedMailAccount] {
        let accountsRoot = home.appendingPathComponent("Library/Accounts")
        let databases: [URL]
        do {
            databases = try fm.contentsOfDirectory(at: accountsRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter {
                    let name = $0.lastPathComponent.lowercased()
                    return name.hasPrefix("accounts") && name.hasSuffix(".sqlite") &&
                        (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } == true
                }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        guard let database = databases.first else { return [] }
        let persistence = try dictionary(mailRoot.appendingPathComponent("PersistenceInfo.plist"))
        guard let version = persistence["LastUsedVersionDirectoryName"] as? String,
              version.range(of: "^V[0-9]+$", options: .regularExpression) != nil else {
            throw CleanerError.message("Mail no declara su versión activa en PersistenceInfo.plist.")
        }
        let db = try ReadOnlyMailDatabase(path: database.path)
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.text }
        func table(_ suffix: String) throws -> String {
            let matches = tables.filter { $0.uppercased().hasSuffix(suffix) }
            guard matches.count == 1, let value = matches.first else { throw CleanerError.message("Esquema Accounts no reconocido; no se seleccionaron cuentas.") }
            return value
        }
        let account = try table("ACCOUNT"), type = try table("ACCOUNTTYPE")
        let dataClass = try table("DATACLASS"), enabled = try table("ENABLEDDATACLASSES")
        func column(_ table: String, _ suffix: String) throws -> String {
            let columns = try db.query("PRAGMA table_info(\(ReadOnlyMailDatabase.quote(table)))").compactMap { $0["name"]?.text }
            let matches = columns.filter { $0.uppercased().hasSuffix(suffix) }
            guard matches.count == 1, let value = matches.first else { throw CleanerError.message("Columnas Accounts incompatibles; no se seleccionaron cuentas.") }
            return ReadOnlyMailDatabase.quote(value)
        }
        let q = ReadOnlyMailDatabase.quote
        let aPK = try column(account, "_PK"), aType = try column(account, "ACCOUNTTYPE")
        let aParent = try column(account, "PARENTACCOUNT"), aID = try column(account, "IDENTIFIER")
        let aProperties = try column(account, "DATACLASSPROPERTIES")
        let tPK = try column(type, "_PK"), tID = try column(type, "IDENTIFIER")
        let dPK = try column(dataClass, "_PK"), dName = try column(dataClass, "NAME")
        let eAccount = try column(enabled, "ENABLEDACCOUNTS"), eClass = try column(enabled, "ENABLEDDATACLASSES")
        let sql = """
        SELECT a.\(aID) AS identifier, a.\(aProperties) AS properties
        FROM \(q(account)) AS a JOIN \(q(type)) AS t ON a.\(aType)=t.\(tPK)
        WHERE t.\(tID) IN ('com.apple.account.IMAP','com.apple.account.IMAPMail')
        AND EXISTS (SELECT 1 FROM \(q(enabled)) AS e JOIN \(q(dataClass)) AS d ON e.\(eClass)=d.\(dPK)
          WHERE d.\(dName)='com.apple.Dataclass.Mail'
          AND e.\(eAccount)=CASE WHEN COALESCE(a.\(aParent),0)<>0 THEN a.\(aParent) ELSE a.\(aPK) END)
        """
        var result: [VerifiedMailAccount] = []
        for row in try db.query(sql) {
            if Task.isCancelled { break }
            guard let identifier = row["identifier"]?.text, !identifier.isEmpty, !identifier.contains("/"), identifier != ".", identifier != ".." else { continue }
            let root = mailRoot.appendingPathComponent(version).appendingPathComponent(identifier)
            guard contained(root, in: mailRoot), directory(root) else { continue }
            // Cache absence, permission errors and unknown schemas do not establish an online account.
            let cache: [String: Any]
            do { cache = try dictionary(root.appendingPathComponent(".mboxCache.plist")) }
            catch { issue(root, "No se pudo verificar el estado online de esta cuenta."); continue }
            let offlineValue = cache["takenOffline"]
            let explicitlyOnline = boolean(offlineValue) == false || (offlineValue as? String)?.caseInsensitiveCompare("NO") == .orderedSame
            guard explicitlyOnline else { continue }
            var trash: URL?
            if let data = row["properties"]?.data,
               let value = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self], from: data) as? [String: Any],
               let properties = value["com.apple.Dataclass.Mail"] as? [String: Any],
               let name = properties["TrashMailboxName"] as? String, !name.isEmpty {
                let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
                let candidate = components.reduce(root) { $0.appendingPathComponent($1 + ".mbox") }
                if contained(candidate, in: root), directory(candidate) { trash = candidate }
            }
            result.append(VerifiedMailAccount(root: root, trash: trash, declared: false))
        }
        return result
    }
    mutating func scanAccount(_ account: VerifiedMailAccount) {
        var enumerationErrors: [ScanIssue] = []
        defer { issues.append(contentsOf: enumerationErrors) }
        guard let iterator = fm.enumerator(at: account.root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { path, _ in
            enumerationErrors.append(ScanIssue(path: path.path, message: "No se pudo leer parte de los buzones de Mail.")); return true
        }) else {
            issue(account.root, "No se pudo acceder a los buzones de la cuenta."); return
        }
        while let item = iterator.nextObject() as? URL {
            if Task.isCancelled { return }
            guard let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]), values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
            if let trash = account.trash, item == trash { iterator.skipDescendants(); continue }
            guard values.isDirectory == true, item.lastPathComponent.lowercased() == "attachments" else { continue }
            collectFiles(item, category: "mailAttachments", account: account, onlyMessages: false)
            iterator.skipDescendants()
        }
        if let trash = account.trash {
            guard let iterator = fm.enumerator(at: trash, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { path, _ in
            enumerationErrors.append(ScanIssue(path: path.path, message: "No se pudo leer parte de los buzones de Mail.")); return true
        }) else { return }
            while let item = iterator.nextObject() as? URL {
                if Task.isCancelled { return }
                guard let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]), values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
                if values.isDirectory == true, item.lastPathComponent.lowercased() == "data" {
                    collectFiles(item, category: "mailTrash", account: account, onlyMessages: true)
                    iterator.skipDescendants()
                }
            }
        }
    }
    mutating func collectFiles(_ root: URL, category: String, account: VerifiedMailAccount, onlyMessages: Bool) {
        var errors: [ScanIssue] = []
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { path, _ in
            errors.append(ScanIssue(path: path.path, message: "Mail: no se pudo leer parte del buzón.")); return true
        }) else { issue(root, "No se pudo enumerar el contenido del buzón."); return }
        while let item = iterator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .isRegularFileKey, .fileSizeKey]), values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
            let package = values.isPackage == true
            guard values.isRegularFile == true || package else { continue }
            if package { iterator.skipDescendants() }
            if onlyMessages && !["emlx", "emlxpart"].contains(item.pathExtension.lowercased()) { continue }
            guard contained(item, in: account.root), seen.insert(item.path).inserted else { continue }
            let size = package ? packageSize(item) : UInt64(max(0, values.fileSize ?? 0))
            guard size > 0 else { continue }
            let detail: [String: String] = [
                "group": category == "mailAttachments" ? "\(item.lastPathComponent) · \(size) bytes" : "Mensajes en Papelera",
                "name": item.lastPathComponent,
                "mailAccountPath": account.root.path,
                "mailSource": account.declared ? "userDeclaration" : "accountsDatabase",
                "mailVerification": account.declared ? "Declaración explícita: IMAP/iCloud online con copia remota confirmada" : "Accounts SQLite: Mail habilitado; caché Mail: online"
            ]
            let json = (try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
            targets.append(ScanTarget(path: item.path, category: category, owner: "com.apple.mail", autoselected: true, detail: json))
        }
        issues.append(contentsOf: errors)
    }
    func packageSize(_ root: URL) -> UInt64 {
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var size: UInt64 = 0
        while let item = iterator.nextObject() as? URL {
            if Task.isCancelled { return 0 }
            guard let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]), values.isSymbolicLink != true else { iterator.skipDescendants(); continue }
            if values.isRegularFile == true { size &+= UInt64(max(0, values.fileSize ?? 0)) }
        }
        return size
    }
}

private enum MailSQLValue {
    case text(String), integer(Int64), data(Data), null
    var text: String? { if case let .text(value) = self { value } else { nil } }
    var data: Data? { if case let .data(value) = self { value } else { nil } }
}

/// A single read transaction supplies a consistent WAL-aware snapshot without copying credentials.
private final class ReadOnlyMailDatabase {
    private var connection: OpaquePointer?
    private let deadline = Date().addingTimeInterval(3)
    init(path: String) throws {
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }; connection = nil
            throw CleanerError.message("No se pudo abrir Accounts en modo de solo lectura; revisa el acceso completo al disco.")
        }
        sqlite3_busy_timeout(connection, 250)
        sqlite3_progress_handler(connection, 1_000, { context in
            guard let context else { return 1 }
            let database = Unmanaged<ReadOnlyMailDatabase>.fromOpaque(context).takeUnretainedValue()
            return Date() > database.deadline || Task.isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        guard sqlite3_exec(connection, "PRAGMA query_only=ON; BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            sqlite3_progress_handler(connection, 0, nil, nil)
            sqlite3_close(connection); connection = nil
            throw CleanerError.message("No se pudo obtener una instantánea coherente de Accounts.")
        }
    }
    deinit {
        sqlite3_progress_handler(connection, 0, nil, nil)
        sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
        sqlite3_close(connection)
    }
    static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    func query(_ sql: String) throws -> [[String: MailSQLValue]] {
        var statement: OpaquePointer?
        guard Date() < deadline, !Task.isCancelled,
              sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw CleanerError.message("Esquema de Accounts no reconocido o consulta cancelada.") }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: MailSQLValue]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard rows.count < 10_000, Date() < deadline, !Task.isCancelled else { throw CleanerError.message("Accounts excedió el límite de consulta local.") }
            var row: [String: MailSQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT:
                    if let value = sqlite3_column_text(statement, index) { row[name] = .text(String(cString: value)) }
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard count <= 10 * 1_024 * 1_024 else { throw CleanerError.message("Metadatos de cuenta demasiado grandes.") }
                    if let value = sqlite3_column_blob(statement, index) { row[name] = .data(Data(bytes: value, count: count)) }
                default: row[name] = .null
                }
            }
            rows.append(row); result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw CleanerError.message("La instantánea de Accounts no se pudo leer completamente.") }
        return rows
    }
}
