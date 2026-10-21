import AppKit
import CleanerCore
import Foundation
import Observation
import PrivilegedProtocol
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    enum Phase: String {
        case prepared = "Preparado", scanning = "Escaneando", results = "Resultados"
        case simulating = "Simulando", cleaning = "Limpiando", completed = "Terminado"
    }
    var phase = Phase.prepared
    var items: [Candidate] = []
    var selected: Set<String> = []
    var issues: [ScanIssue] = []
    var visited: UInt64 = 0
    var outcomes: [ItemOutcome] = []
    var lastReport: CleaningReport?
    var reportURL: URL?
    var error: String?
    var userRules = Rules()
    var cancelRequested = false
    var discoveryStatus = ""
    var cleaningTotal = 0
    var fixtureMode = false
    let home: URL
    let storage: Storage
    private var engine: Engine?
    private var discoveryTask: Task<DiscoveryResult, Never>?
    private let runner = CleaningRunner()
    let privilegedClient = PrivilegedClient()
    var helperStatus: PrivilegedStatus?
    var access: [DiskAccess] = []
    private var helperScanID: String?
    private var helperItems: [String: HelperItem] = [:]
    var includeAdvanced = UserDefaults.standard.bool(forKey: "includeAdvancedCleanup") {
        didSet { UserDefaults.standard.set(includeAdvanced, forKey: "includeAdvancedCleanup") }
    }
    func refreshAccess() {
        helperStatus = privilegedClient.status()
        let scanHome = home
        Task { access = await Task.detached(priority: .utility) { DiskAccess.inspect(home: scanHome) }.value }
    }
    func registerHelper() {
        do { try privilegedClient.register(); refreshAccess() } catch { self.error = error.localizedDescription; refreshAccess() }
    }
    func unregisterHelper() {
        Task { do { try await privilegedClient.unregister(); refreshAccess() } catch { self.error = error.localizedDescription } }
    }
    func chooseApplication() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Revisar una aplicación y sus recursos"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { scan(application: url) }
    }
    func saveMailAccount(account: URL, trash: URL?, type: String, remoteCopyConfirmed: Bool) throws {
        guard remoteCopyConfirmed else { throw CleanerError.message("Confirma primero que el servidor conserva una copia de tus mensajes y adjuntos.") }
        let root = home.appendingPathComponent("Library/Mail").resolvingSymlinksInPath().path + "/"
        let path = account.resolvingSymlinksInPath().path
        guard path.hasPrefix(root), let version = path.dropFirst(root.count).split(separator: "/").first,
              version.first == "V", version.dropFirst().allSatisfy(\.isNumber),
              trash == nil || trash!.resolvingSymlinksInPath().path.hasPrefix(path + "/") else {
            throw CleanerError.message("Selecciona una cuenta dentro de Library/Mail/V… y una papelera dentro de esa cuenta.")
        }
        let url = MailDiscovery.configurationURL(home: home)
        var accounts: [MailAccountMetadata] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try JSONDecoder().decode(MailDiscoveryMetadata.self, from: Data(contentsOf: url))
            guard existing.version == 1 else { throw CleanerError.message("Configuración de Mail incompatible.") }
            accounts = existing.accounts.filter { $0.accountPath != path }
        }
        accounts.append(MailAccountMetadata(accountPath: path, accountType: type, enabled: true, offline: false,
                                            remoteCopyConfirmed: true, trashPath: trash?.resolvingSymlinksInPath().path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(MailDiscoveryMetadata(accounts: accounts)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    var busy: Bool { [.scanning, .simulating, .cleaning].contains(phase) }
    var canClean: Bool { !busy && engine != nil && !selected.isEmpty && !cancelRequested }
    private func outermost(_ candidates: [Candidate]) -> [Candidate] {
        var roots: [Candidate] = []
        for item in candidates.sorted(by: { $0.path + "/" < $1.path + "/" }) {
            if let previous = roots.last, item.path == previous.path || item.path.hasPrefix(previous.path + "/") { continue }
            roots.append(item)
        }
        return roots
    }
    var selectedItems: [Candidate] {
        outermost(items.filter { selected.contains($0.id) && $0.selectable }).sorted { $0.path < $1.path }
    }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.allocated_bytes } }
    var totalBytes: UInt64 { outermost(items.filter(\.selectable)).reduce(0) { $0 + $1.allocated_bytes } }

    init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--fixture-home"), args.indices.contains(index + 1) {
            fixtureMode = true
            home = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath()
            storage = Storage(directory: home.appendingPathComponent(".cleaner-test"))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            storage = Storage()
        }
        do { userRules = try storage.loadRules() } catch { self.error = error.localizedDescription }
    }
    func scan(application: URL? = nil) {
        guard !busy else { return }
        helperScanID = nil; helperItems = [:]
        phase = .scanning; items = []; selected = []; issues = []; outcomes = []; visited = 0
        error = nil; cancelRequested = false; lastReport = nil; reportURL = nil
        discoveryStatus = "Identificando aplicaciones y ubicaciones…"
        let oldEngine = engine; engine = nil
        Task {
            oldEngine?.cancel()
            do {
                userRules = try storage.loadRules()
                let rules = try Storage.bundledRules().merging(userRules)
                let scanHome = home
                let inventory = await Task.detached(priority: .utility) { ApplicationInventory.discover(home: scanHome) }.value
                guard !cancelRequested else { phase = .results; return }
                discoveryStatus = "Buscando cachés, copias, descargas, Mail y archivos de desarrollo…"
                let advancedEnabled = includeAdvanced
                let providerTask = Task.detached(priority: .utility) {
                    if let application { return RelatedFilesDiscovery.resources(for: application, home: scanHome) }
                    let basic = MacOSDiscovery.discover(home: scanHome, inventory: inventory, includeSystem: true)
                    if Task.isCancelled { return DiscoveryResult(targets: [], issues: []) }
                    let related = RelatedFilesDiscovery.discover(home: scanHome, installedBundleIDs: inventory.bundleIDs, containerOwners: inventory.containerOwners)
                    if Task.isCancelled { return DiscoveryResult(targets: [], issues: []) }
                    let advanced = AdvancedDiscovery.discover(home: scanHome)
                    let mail = MailDiscovery.discover(home: scanHome)
                    let extra = AdditionalDiscovery.discover(home: scanHome, includeAdvanced: advancedEnabled)
                    return DiscoveryResult(targets: basic.targets + related.targets + advanced.targets + mail.targets + extra.targets,
                        issues: basic.issues + related.issues + advanced.issues + mail.issues + extra.issues)
                }
                discoveryTask = providerTask
                let discovery = await providerTask.value
                discoveryTask = nil
                guard !cancelRequested else { phase = .results; return }
                issues.append(contentsOf: discovery.issues)
                let newEngine = try Engine(home: home, rules: rules, installedBundleIDs: inventory.bundleIDs, containerOwners: inventory.containerOwners, targets: discovery.targets, runningBundleIDs: CleaningRunner.runningBundleIDs, cacheOwners: inventory.cacheOwners, includeDefaultCategories: application == nil)
                discoveryStatus = "Midiendo archivos y verificando seguridad…"
                engine = newEngine
                while true {
                    if cancelRequested { newEngine.cancel() }
                    let batch = try await newEngine.poll()
                    items.append(contentsOf: batch.items)
                    if !cancelRequested { selected.formUnion(batch.items.filter { $0.autoselected && $0.selectable }.map(\.id)) }
                    issues.append(contentsOf: batch.errors); visited = batch.visited
                    if batch.done {
                        if batch.cancelled { cancelRequested = true; selected = []; engine = nil }
                        break
                    }
                    try await Task.sleep(for: .milliseconds(80))
                }
                if application == nil, !fixtureMode, !cancelRequested, privilegedClient.status().canScan {
                    discoveryStatus = "Escaneando cachés y logs con el helper autorizado…"
                    do {
                        let result = try await privilegedClient.scan(exclusions: HelperExclusions(paths: rules.paths, names: rules.names))
                        if !cancelRequested {
                            helperScanID = result.scanID
                            for item in result.items {
                                let relative = item.path.replacingOccurrences(of: "/Library/Caches/", with: "").replacingOccurrences(of: "/Library/Logs/", with: "")
                                let owner = inventory.cacheOwners[relative] ?? inventory.cacheOwners[relative.components(separatedBy: "/").first ?? ""]
                                if let owner, rules.bundle_ids.contains(owner) { continue }
                                let candidate = Candidate(helperItem: item, owner: owner, runningBundleIDs: CleaningRunner.runningBundleIDs)
                                let oldIDs = items.filter { $0.path == candidate.path }.map(\.id)
                                selected.subtract(oldIDs); items.removeAll { $0.path == candidate.path }
                                helperItems[candidate.id] = item; items.append(candidate)
                            }
                            issues.append(contentsOf: result.issues.map { ScanIssue(path: $0.path, message: $0.message) })
                        }
                    } catch { issues.append(ScanIssue(path: "/Library", message: error.localizedDescription)) }
                }
                items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                phase = .results
            } catch {
                self.error = error.localizedDescription
                engine?.cancel(); engine = nil; selected = []; phase = .results
            }
        }
    }
    func cancel() {
        cancelRequested = true
        runner.cancel()
        discoveryTask?.cancel()
        if let engine { engine.cancel() }
    }
    func clean(simulate: Bool) {
        guard canClean, let engine else { return }
        let targets = selectedItems
        cleaningTotal = targets.count
        phase = simulate ? .simulating : .cleaning
        outcomes = []; error = nil; cancelRequested = false
        Task {
            do {
                guard !cancelRequested else { phase = .completed; return }
                let rules = try Storage.bundledRules().merging(storage.loadRules())
                let localTargets = targets.filter { $0.cleanup_action != "privileged" }
                let localReport = await runner.run(items: localTargets, engine: engine, rules: rules, simulate: simulate, home: home) { result in
                    self.outcomes.append(result)
                    if ["trashed", "removed"].contains(result.status) {
                        self.items.removeAll { $0.id == result.id }
                        self.selected.remove(result.id)
                    }
                }
                var results = localReport.items
                if !localReport.cancelled {
                    for target in targets where target.cleanup_action == "privileged" {
                        if cancelRequested { break }
                        let result: ItemOutcome
                        do {
                            guard let scanID = helperScanID, let item = helperItems[target.id] else { throw CleanerError.message("La sesión privilegiada venció; vuelve a escanear.") }
                            if let owner = target.owner {
                                guard !rules.bundle_ids.contains(owner) else { throw CleanerError.message("La app propietaria está excluida.") }
                                guard !CleaningRunner.runningBundleIDs.contains(owner) else { throw CleanerError.message("La app propietaria está en ejecución.") }
                            }
                            let exclusions = HelperExclusions(paths: rules.paths, names: rules.names)
                            let checked = try await privilegedClient.validate(scanID: scanID, token: item.token, exclusions: exclusions)
                            guard checked.valid else { throw CleanerError.message(checked.reason ?? "Objetivo privilegiado no válido.") }
                            if cancelRequested { break }
                            if let owner = target.owner, CleaningRunner.runningBundleIDs.contains(owner) { throw CleanerError.message("La app propietaria está en ejecución.") }
                            if simulate { result = ItemOutcome(id: target.id, path: target.path, status: "simulated") }
                            else {
                                let reply = try await privilegedClient.remove(scanID: scanID, tokens: [item.token], confirmed: true, exclusions: exclusions)
                                guard let outcome = reply.outcomes.first, outcome.token == item.token else { throw CleanerError.message("Respuesta privilegiada incompleta.") }
                                result = ItemOutcome(id: target.id, path: target.path, status: outcome.status, message: outcome.message, recoveryPath: outcome.quarantinePath)
                            }
                        } catch { result = ItemOutcome(id: target.id, path: target.path, status: "failed", message: error.localizedDescription) }
                        results.append(result); outcomes.append(result)
                        if result.status == "removed" { items.removeAll { $0.id == target.id }; selected.remove(target.id) }
                    }
                }
                let report = CleaningReport(simulated: simulate, cancelled: cancelRequested || localReport.cancelled, items: results)
                lastReport = report
                reportURL = try storage.saveReport(report)
            } catch { self.error = error.localizedDescription }
            phase = .completed
        }
    }
    func exclude(_ item: Candidate) {
        guard !busy else { return }
        var next = userRules
        if !next.paths.contains(item.path) { next.paths.append(item.path) }
        do {
            try storage.saveRules(next); userRules = next
            let root = URL(fileURLWithPath: item.path).path + "/"
            let excluded = items.filter { $0.path == item.path || $0.path.hasPrefix(root) }.map(\.id)
            selected.subtract(excluded); items.removeAll { excluded.contains($0.id) }
        } catch { self.error = error.localizedDescription }
    }
    func removeExclusion(_ path: String) {
        var next = userRules; next.paths.removeAll { $0 == path }
        do { try storage.saveRules(next); userRules = next } catch { self.error = error.localizedDescription }
    }
    func toggle(_ candidates: [Candidate]) {
        guard !busy && !cancelRequested else { return }
        let ids = Set(candidates.filter(\.selectable).map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }
}
