import AppKit
import CleanerCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var category = "all"
    @State private var search = ""
    @State private var expanded = Set(CleanupCategory.allCases.map(\.rawValue))
    @State private var confirmCleaning = false
    @State private var showReport = false
    @State private var showExclusions = false
    @State private var showAccess = false
    @State private var mailAccount: URL?
    @State private var mailTrash: URL?
    @State private var mailType = "IMAPAccount"
    @State private var mailRemoteConfirmed = false
    @State private var accessMessage: String?
    @AppStorage("showLogicalSizes") private var showLogicalSizes = false
    private var visibleCategories: [CleanupCategory] { CleanupCategory.allCases.filter { category == "all" || category == $0.rawValue } }
    private var irreversibleCount: Int { model.selectedItems.filter(\.irreversible).count }
    private var cleanupLabel: String { irreversibleCount == 0 ? "Mover a la Papelera" : "Limpiar selección" }
    private var cleanupMessage: String {
        let reversible = model.selectedItems.count - irreversibleCount
        return "\(byteString(model.selectedBytes)) estimados. \(reversible) elementos se moverán a la Papelera."
            + (irreversibleCount > 0 ? " \(irreversibleCount) elementos de la Papelera, simuladores, versiones u operaciones avanzadas del sistema se eliminarán definitivamente. Esta parte no se puede deshacer." : " Podrás recuperarlos desde la Papelera; el espacio se libera al vaciarla.")
    }
    private let sections = ["Basura del sistema", "Correo", "Archivos y papeleras", "Aplicaciones", "Desarrollo"]

    private struct Presentation {
        let groups: [String: [Candidate]]
        let filtered: [String: [Candidate]]
        let selected: [Candidate]
        let selectedBytes: UInt64
        let totalBytes: UInt64

        @MainActor init(model: AppModel, search: String) {
            groups = Dictionary(grouping: model.items, by: \.category)
            filtered = search.isEmpty ? groups : Dictionary(grouping: model.items.filter {
                $0.path.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)
            }, by: \.category)
            selected = model.selectedItems
            selectedBytes = selected.reduce(0) { $0 + $1.allocated_bytes }
            totalBytes = model.totalBytes
        }
    }

    var body: some View {
        let presentation = Presentation(model: model, search: search)
        NavigationSplitView {
            sidebar(presentation)
                .navigationSplitViewColumnWidth(min: 235, ideal: 250, max: 290)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary(presentation)
                        HStack(spacing: 12) {
                            CleanerStat(title: "En la selección", value: byteString(presentation.selectedBytes), subtitle: "\(presentation.selected.count) elementos revisables", symbol: "checkmark.circle", color: CleanerStyle.accent)
                            CleanerStat(title: "Archivos encontrados", value: model.items.count.formatted(), subtitle: "\(presentation.groups.count) categorías con resultados", symbol: "doc.on.doc", color: .blue)
                            CleanerStat(title: "Incidencias de acceso", value: model.issues.count.formatted(), subtitle: model.issues.isEmpty ? "Sin incidencias registradas" : "Revisa los permisos de tu Mac", symbol: model.issues.isEmpty ? "shield.lefthalf.filled" : "exclamationmark.shield", color: model.issues.isEmpty ? CleanerStyle.accent : .orange)
                        }
                        if let error = model.error { notice(error, icon: "exclamationmark.triangle", color: .orange) }
                        if model.cancelRequested && !model.busy {
                            notice("Operación cancelada. Los traslados completados se conservan. Vuelve a escanear para continuar.", icon: "stop.circle", color: .secondary)
                        }
                        if model.items.isEmpty { emptyState }
                    }.padding(24)
                }
                .frame(maxHeight: model.items.isEmpty ? .infinity : 350)
                if !model.items.isEmpty { results(presentation) }
                if !model.issues.isEmpty { issues }
                actions(presentation)
            }
            .background(CleanerStyle.canvas)
            .toolbar {
                ToolbarItemGroup {
                    if model.busy {
                        Button("Cancelar", systemImage: "stop.circle") { model.cancel() }.disabled(model.cancelRequested)
                    }
                    Menu {
                        Button("Revisar una aplicación para desinstalar…") { model.chooseApplication() }.disabled(model.busy)
                        Button("Acceso, helper y cuentas de Mail…") { showAccess = true }
                        Toggle("Incluir cuarentena y diagnósticos avanzados", isOn: $model.includeAdvanced).disabled(model.busy)
                        Button("Permitir acceso completo al disco…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Toggle("Mostrar tamaños lógicos", isOn: $showLogicalSizes)
                        Button("Ver exclusiones") { showExclusions = true }.disabled(model.busy)
                        Button("Ver último informe") { showReport = true }.disabled(model.lastReport == nil)
                        Button("Abrir carpeta de informes") { NSWorkspace.shared.open(model.storage.directory.appendingPathComponent("Reports")) }
                    } label: { Image(systemName: "ellipsis.circle") }.help("Opciones")
                }
            }
        }
        .tint(CleanerStyle.accent)
        .confirmationDialog(cleanupLabel, isPresented: $confirmCleaning, titleVisibility: .visible) {
            Button("\(cleanupLabel): \(model.selectedItems.count) elementos", role: .destructive) { model.clean(simulate: false) }
            Button("Cancelar", role: .cancel) {}
        } message: { Text(cleanupMessage) }
        .sheet(isPresented: $showReport) { reportSheet }
        .sheet(isPresented: $showExclusions) { exclusionSheet }
        .sheet(isPresented: $showAccess) { accessSheet }
    }

    private func sidebar(_ presentation: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(CleanerStyle.accent)
                    .frame(width: 40, height: 40).background(CleanerStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("TidyMac").font(.system(size: 17, weight: .semibold))
                    Text("MAC CLEANER").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(CleanerStyle.muted)
                }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 26)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    navigationRow(title: "Vista general", symbol: "square.grid.2x2", id: "all", count: model.items.count)
                    ForEach(sections, id: \.self) { section in
                        Text(section.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2)
                            .foregroundStyle(CleanerStyle.muted).padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 6)
                        ForEach(CleanupCategory.allCases.filter { $0.section == section }) { value in
                            navigationRow(title: value.title, symbol: value.icon, id: value.rawValue, count: presentation.groups[value.rawValue]?.count ?? 0)
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 16) {
                Button { model.chooseApplication() } label: { Label("Desinstalar una app…", systemImage: "app.badge").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).disabled(model.busy)
                Button { showAccess = true } label: { Label("Acceso y permisos", systemImage: "lock.shield").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain)
                Button { showExclusions = true } label: {
                    Label("Exclusiones", systemImage: "hand.raised").font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.buttonStyle(.plain).disabled(model.busy)
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 20)).foregroundStyle(CleanerStyle.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.fixtureMode ? "Mac de prueba" : "En este Mac").font(.system(size: 12, weight: .medium))
                        Text(model.fixtureMode ? "HOME temporal" : "Local · Sin servicios remotos").font(.system(size: 10)).foregroundStyle(CleanerStyle.muted)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(CleanerStyle.accent).frame(width: 6, height: 6)
                }
            }.padding(20)
        }
        .foregroundStyle(.white)
        .background(CleanerStyle.sidebar.ignoresSafeArea())
        .toolbar(removing: .sidebarToggle)
    }

    private func navigationRow(title: String, symbol: String, id: String, count: Int) -> some View {
        let active = category == id
        return Button { category = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: active ? .semibold : .regular)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                if count > 0 { Text(count.formatted()).font(.system(size: 10, weight: .medium).monospacedDigit()).opacity(0.8) }
            }
            .foregroundStyle(active ? CleanerStyle.accent : Color.white.opacity(0.78))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(active ? CleanerStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category == "all" ? "Un poco de orden. Mucho espacio." : CleanupCategory(rawValue: category)?.title ?? "Limpieza")
                    .font(.system(size: 23, weight: .semibold))
                Text("Tu almacenamiento, bajo control.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.phase.rawValue, systemImage: model.busy ? "clock" : "circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(model.busy ? .secondary : CleanerStyle.accent)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(CleanerStyle.surface, in: Capsule())
        }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 4)
    }

    private func summary(_ presentation: Presentation) -> some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Label("ESPACIO RECUPERABLE ESTIMADO", systemImage: "internaldrive")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(CleanerStyle.muted)
                Text(model.phase == .prepared ? "Haz espacio para más." : byteString(presentation.totalBytes))
                    .font(.system(size: model.phase == .prepared ? 32 : 42, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white)
                Text(model.phase == .prepared ? "Encuentra cachés y archivos que ya no necesitas.\nRevisa cada resultado y decide qué limpiar." : "Revisa los archivos antes de limpiar. Los totales\nno duplican rutas anidadas.")
                    .font(.system(size: 12)).foregroundStyle(CleanerStyle.muted).fixedSize(horizontal: false, vertical: true)
                if model.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.phase == .scanning ? model.discoveryStatus : "\(model.outcomes.count) de \(model.cleaningTotal) elementos procesados")
                            .font(.caption).foregroundStyle(.white).lineLimit(2)
                    }
                    if model.phase == .scanning {
                        Text("\(model.visited.formatted()) entradas verificadas").font(.caption2).foregroundStyle(CleanerStyle.muted).monospacedDigit()
                    } else {
                        ProgressView(value: Double(model.outcomes.count), total: Double(max(model.cleaningTotal, 1))).tint(CleanerStyle.accent)
                    }
                } else {
                    Button { model.scan() } label: {
                        Label(model.phase == .prepared ? "Analizar mi Mac" : "Volver a escanear", systemImage: "magnifyingglass")
                    }.buttonStyle(CleanerPrimaryButtonStyle()).keyboardShortcut("r", modifiers: .command)
                }
                if let report = model.lastReport {
                    Button { showReport = true } label: {
                        Label("\(report.simulated ? "Simulación" : "Limpieza"): \(report.items.filter { $0.status != "failed" }.count) correctos · \(report.items.filter { $0.status == "failed" }.count) fallidos → Ver informe", systemImage: "doc.text")
                            .font(.caption).foregroundStyle(CleanerStyle.accent)
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            StorageRing(fraction: presentation.totalBytes == 0 ? 0 : Double(presentation.selectedBytes) / Double(presentation.totalBytes), hasResults: !model.items.isEmpty, busy: model.busy)
        }
        .padding(28)
        .background(LinearGradient(colors: [CleanerStyle.ink, Color(red: 0.075, green: 0.20, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
    }

    private func results(_ presentation: Presentation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Revisar archivos").font(.system(size: 15, weight: .semibold))
                    Text(showLogicalSizes ? "Tamaños lógicos por elemento" : "Espacio físico estimado por elemento").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar nombre o ruta", text: $search).textFieldStyle(.plain)
                        .accessibilityLabel("Buscar por nombre o ruta")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Borrar búsqueda")
                    }
                }.font(.system(size: 12)).padding(9).frame(width: 230)
                    .background(CleanerStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary, lineWidth: 1) }
            }.padding(.horizontal, 24).padding(.bottom, 12)
            Divider()
            List {
                ForEach(visibleCategories) { value in
                    let items = presentation.filtered[value.rawValue] ?? []
                    if !items.isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(value.rawValue) }, set: { if $0 { expanded.insert(value.rawValue) } else { expanded.remove(value.rawValue) } })) {
                            resultRows(items)
                        } label: {
                            HStack(spacing: 10) {
                                selectionButton(items, label: "Seleccionar \(value.title)")
                                CategorySymbol(symbol: value.icon, color: CleanerStyle.color(for: value.section), size: 30)
                                Text(value.title).font(.system(size: 13, weight: .semibold))
                                Text("\(items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 3).background(.primary.opacity(0.05), in: Capsule())
                                Spacer()
                                Text(byteString(items.reduce(0) { $0 + (showLogicalSizes ? $1.logical_bytes : $1.allocated_bytes) }))
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }.listRowSeparator(.hidden)
                    }
                }
            }.listStyle(.inset).scrollContentBackground(.hidden)
                .overlay {
                    if visibleCategories.allSatisfy({ presentation.filtered[$0.rawValue]?.isEmpty != false }) {
                        ContentUnavailableView {
                            Label(search.isEmpty ? "Categoría sin resultados" : "Sin coincidencias", systemImage: search.isEmpty ? "tray" : "magnifyingglass")
                        } description: { Text(search.isEmpty ? "No se encontraron archivos en esta categoría." : "Prueba con otro nombre o ruta.") }
                    }
                }
        }.frame(maxHeight: .infinity)
    }

    @ViewBuilder private func resultRows(_ items: [Candidate]) -> some View {
        if items.first?.category == "mailAttachments" {
            let copies = Dictionary(grouping: items, by: { $0.attachmentGroup ?? $0.path })
            ForEach(copies.keys.sorted(), id: \.self) { key in
                let members = copies[key] ?? []
                if members.count > 1 {
                    DisclosureGroup {
                        ForEach(members) { row($0) }
                    } label: {
                        HStack {
                            selectionButton(members, label: "Seleccionar copias de \(members.first?.name ?? key)")
                            Text(members.first?.name ?? key)
                            Text("\(members.count) copias").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(byteString(members.reduce(0) { $0 + (showLogicalSizes ? $1.logical_bytes : $1.allocated_bytes) })).font(.caption.monospacedDigit())
                        }
                    }
                } else { ForEach(members) { row($0) } }
            }
        } else { ForEach(items) { row($0) } }
    }

    private var issues: some View {
        DisclosureGroup {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.path).font(.caption).textSelection(.enabled)
                            Text(issue.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
        } label: { Label("\(model.issues.count) incidencias de acceso o escaneo", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
        .font(.caption).padding(.horizontal, 24).padding(.vertical, 10)
    }
    private func row(_ item: Candidate) -> some View {
        HStack(spacing: 12) {
            selectionButton([item], label: "Seleccionar \(item.name)")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.body.weight(.medium))
                Text(item.path.replacingOccurrences(of: model.home.path, with: "~", options: [.anchored]))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let reason = item.blocked_reason {
                    Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.orange)
                } else if let owner = item.owner {
                    Text(owner).font(.caption2).foregroundStyle(.secondary)
                } else if ["userCaches", "containerCaches", "darwinCaches", "userLogs", "containerLogs", "electronCaches", "appCaches"].contains(item.category) {
                    Text("Propietario no identificado; comprueba que no esté en uso.").font(.caption2).foregroundStyle(.secondary)
                }
                if let detail = item.detail, !detail.hasPrefix("{") { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                if item.dependency_running { Label("App abierta al escanear; ciérrala antes de seleccionar.", systemImage: "app.badge").font(.caption2).foregroundStyle(.orange) }
                if item.irreversible { Label("Eliminación definitiva al limpiar", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer(minLength: 12)
            Text(byteString(showLogicalSizes ? item.logical_bytes : item.allocated_bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Mostrar en Finder").accessibilityLabel("Mostrar \(item.name) en Finder")
        }
        .padding(.vertical, 9)
        .listRowSeparator(.hidden)
        .listRowBackground(model.selected.contains(item.id) ? CleanerStyle.accent.opacity(0.05) : Color.clear)
        .help(item.path)
        .contextMenu {
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Button("Excluir esta ruta") { model.exclude(item) }.disabled(model.busy)
        }
    }
    private func selectionButton(_ items: [Candidate], label: String) -> some View {
        let eligible = items.filter(\.selectable)
        let count = eligible.filter { model.selected.contains($0.id) }.count
        let icon = count == 0 ? "square" : count == eligible.count ? "checkmark.square.fill" : "minus.square.fill"
        return Button { model.toggle(items) } label: {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(eligible.isEmpty || model.busy || model.cancelRequested)
            .accessibilityLabel(label).accessibilityValue(count == 0 ? "Sin seleccionar" : count == eligible.count ? "Seleccionado" : "Selección parcial")
    }
    private func actions(_ presentation: Presentation) -> some View {
        HStack(spacing: 12) {
            CategorySymbol(symbol: "checkmark.shield", color: CleanerStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(presentation.selected.count) seleccionados · \(byteString(presentation.selectedBytes))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text("El espacio se libera al vaciar la Papelera.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Simular") { model.clean(simulate: true) }.controlSize(.large).disabled(!model.canClean)
                .help("Verificar la selección sin mover ni eliminar archivos")
            Button(cleanupLabel, systemImage: "trash") { confirmCleaning = true }
                .buttonStyle(CleanerPrimaryButtonStyle()).disabled(!model.canClean)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(CleanerStyle.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.phase == .prepared ? "Una limpieza con criterio" : model.busy ? "Analizando tu almacenamiento" : "Sin archivos encontrados")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("TÚ DECIDES").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            }
            if model.phase == .prepared {
                feature("Encuentra lo prescindible", description: "Cachés, logs, descargas y archivos de desarrollo, organizados por categoría.", symbol: "square.stack.3d.up", color: .blue)
                feature("Revisa antes de limpiar", description: "Consulta cada ruta, ajusta la selección y simula el resultado antes de continuar.", symbol: "checklist", color: CleanerStyle.accent)
                feature("Todo ocurre en tu Mac", description: "Sin servicios remotos. Tus archivos y los informes permanecen aquí.", symbol: "lock.shield", color: .purple)
            } else {
                Label(model.busy ? "Los resultados aparecerán a medida que avance el escaneo. Puedes cancelarlo cuando quieras." : "No se encontraron elementos en las ubicaciones accesibles. Revisa las incidencias de permisos.", systemImage: model.busy ? "magnifyingglass" : "tray")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
            }
        }.padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CleanerStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06), lineWidth: 1) }
    }

    private func feature(_ title: String, description: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 14) {
            CategorySymbol(symbol: symbol, color: color, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(color).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private var reportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Informe de \(model.lastReport?.simulated == true ? "simulación" : "limpieza")", systemImage: "doc.text.magnifyingglass").font(.title2.weight(.semibold))
            if model.lastReport?.simulated == true { Text("No se movió ningún archivo.").foregroundStyle(.secondary) }
            if model.lastReport?.cancelled == true { Text("Operación cancelada; se conservan los resultados completados.").foregroundStyle(.secondary) }
            List(model.lastReport?.items ?? [], id: \.id) { result in
                VStack(alignment: .leading, spacing: 5) {
                    Label(result.status == "failed" ? "Falló" : result.status == "simulated" ? "Validado" : result.status == "removed" ? "Eliminado" : "En la Papelera", systemImage: result.status == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
                    Text(result.path).font(.caption).textSelection(.enabled)
                    if let path = result.recoveryPath {
                        Button("Mostrar copia de recuperación") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.font(.caption)
                    }
                    if let message = result.message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(.vertical, 4)
            }
            HStack {
                if let url = model.reportURL { Button("Mostrar JSON") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Spacer(); Button("Cerrar") { showReport = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 680, height: 480).background(CleanerStyle.canvas)
    }
    private func chooseMailFolder(trash: Bool) {
        let panel = NSOpenPanel()
        panel.title = trash ? "Selecciona el buzón de papelera de esta cuenta" : "Selecciona la carpeta de la cuenta de Mail"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = trash ? mailAccount : model.home.appendingPathComponent("Library/Mail")
        if panel.runModal() == .OK, let url = panel.url {
            if trash { mailTrash = url } else { mailAccount = url; mailTrash = nil }
        }
    }
    private var accessSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Acceso y operaciones del sistema").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Acceso a tus datos") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.access) { item in HStack { Text(item.title); Spacer(); Text(item.status).foregroundStyle(.secondary) } }
                            Button("Abrir Acceso completo al disco") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                            Text("Añade esta aplicación en Ajustes y vuelve a escanear. El permiso de disco y los privilegios de administrador son independientes.").font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    GroupBox("Helper privilegiado") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.helperStatus?.message ?? "Comprobando estado…").font(.callout).textSelection(.enabled)
                            HStack {
                                Button("Activar helper") { model.registerHelper() }.disabled(model.helperStatus?.canRegister != true || model.busy)
                                Button("Autorizar en Ajustes") { model.privilegedClient.openApprovalSettings() }
                                Button("Desactivar") { model.unregisterHelper() }.disabled(model.helperStatus?.canScan != true || model.busy)
                            }
                            Text("Solo cachés y logs de ubicaciones permitidas. Cada limpieza privilegiada es definitiva y necesita selección manual.").font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    GroupBox("Cuenta de Mail declarada manualmente") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Úsalo si macOS no permite verificar automáticamente la cuenta. Selecciona su carpeta en Mail/V…; admite IMAP e iCloud conectados, con copia en el servidor.").font(.caption).foregroundStyle(.secondary)
                            HStack { Button("Seleccionar cuenta…") { chooseMailFolder(trash: false) }; Text(mailAccount?.lastPathComponent ?? "Sin seleccionar").font(.caption) }
                            HStack { Button("Papelera de la cuenta…") { chooseMailFolder(trash: true) }.disabled(mailAccount == nil); Text(mailTrash?.lastPathComponent ?? "Opcional").font(.caption) }
                            Picker("Tipo", selection: $mailType) { Text("IMAP").tag("IMAPAccount"); Text("iCloud").tag("AosImapAccount") }.pickerStyle(.segmented)
                            Toggle("Confirmo que la cuenta está conectada y el servidor conserva los originales", isOn: $mailRemoteConfirmed)
                            Button("Guardar cuenta para el próximo escaneo") {
                                guard let account = mailAccount else { return }
                                do { try model.saveMailAccount(account: account, trash: mailTrash, type: mailType, remoteCopyConfirmed: mailRemoteConfirmed); accessMessage = "Cuenta guardada. Vuelve a escanear." }
                                catch { accessMessage = error.localizedDescription }
                            }.disabled(mailAccount == nil || !mailRemoteConfirmed || model.busy)
                        }.padding(8)
                    }
                    if let message = accessMessage { Text(message).font(.callout).textSelection(.enabled) }
                }
            }
            HStack { Button("Actualizar estado") { model.refreshAccess() }; Spacer(); Button("Cerrar") { showAccess = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 720, height: 650).background(CleanerStyle.canvas).onAppear { model.refreshAccess() }
    }

    private var exclusionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Exclusiones persistentes", systemImage: "hand.raised").font(.title2.weight(.semibold))
            Text("Excluye una ruta desde el menú contextual de un resultado. Tras quitar una exclusión, vuelve a escanear.").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.userRules.paths, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption).textSelection(.enabled)
                        Spacer(); Button("Quitar") { model.removeExclusion(path) }
                    }
                }
                ForEach(model.userRules.names, id: \.self) { name in Text("Nombre: \(name)") }
                ForEach(model.userRules.bundle_ids, id: \.self) { id in Text("App: \(id)") }
            }
            HStack {
                Button("Abrir carpeta de configuración") {
                    do {
                        try FileManager.default.createDirectory(at: model.storage.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.storage.directory)
                    } catch { model.error = error.localizedDescription }
                }
                Spacer(); Button("Cerrar") { showExclusions = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 680, height: 400).background(CleanerStyle.canvas)
    }
}
