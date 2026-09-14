const invoke = window.__TAURI__?.core?.invoke;
const isTauri = typeof invoke === "function";

const state = {
  summary: null, sampleReport: null, classification: "REVIEW", category: "", offset: 0, limit: 60,
  query: "", totalResults: 0, loading: false, developerMode: false, loadedItems: [],
  selected: new Map(), cleanupPlan: null, dialogMode: "confirm", reportValid: false,
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function formatBytes(bytes, precise = false) {
  if (bytes == null || Number.isNaN(Number(bytes))) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = Math.max(0, Number(bytes)); let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  const digits = unit < 2 ? 0 : precise ? 2 : 1;
  return `${value.toLocaleString("es-MX", { maximumFractionDigits: digits, minimumFractionDigits: digits })} ${units[unit]}`;
}

function compactNumber(number) {
  return new Intl.NumberFormat("es-MX", { notation: "compact", maximumFractionDigits: 1 }).format(number || 0);
}

function homePath(path) {
  const home = state.summary?.home_breakdown?.find((row) => row.path?.includes("/Library"))?.path?.replace(/\/Library$/, "");
  return home && path.startsWith(`${home}/`) ? `~/${path.slice(home.length + 1)}` : path;
}

function classifyMeta(classification) {
  return {
    SAFE: { eyebrow: "REGENERABLE · CONFIRMACIÓN OBLIGATORIA", title: "Seguro para limpiar", subtitle: "Archivos antiguos bajo raíces conocidas. Puedes inspeccionar cada ruta antes de confirmar.", className: "safe" },
    REVIEW: { eyebrow: "DECISIÓN HUMANA", title: "Requiere tu revisión", subtitle: "Nada está preseleccionado. La acción recomendada es mover a la Papelera.", className: "review" },
    PROTECTED: { eyebrow: "SOLO ESTADÍSTICAS", title: "Protegido explícitamente", subtitle: "Estas ubicaciones se miden, pero la app se niega a modificarlas.", className: "protected" },
  }[classification];
}

function iconSvg(classification) {
  if (classification === "SAFE") return '<svg viewBox="0 0 24 24"><path d="m5 12.5 4.2 4.2L19.5 6.5"/></svg>';
  if (classification === "REVIEW") return '<svg viewBox="0 0 24 24"><path d="M12 3.5 21 20H3L12 3.5Z"/><path d="M12 9v5m0 3h.01"/></svg>';
  return '<svg viewBox="0 0 24 24"><rect x="5" y="10" width="14" height="10" rx="3"/><path d="M8.5 10V7.5a3.5 3.5 0 0 1 7 0V10"/></svg>';
}

function createElement(tag, className, text) {
  const element = document.createElement(tag); if (className) element.className = className;
  if (text !== undefined) element.textContent = text; return element;
}

function itemActionable(item) {
  return item.classification === "REVIEW" && item.metadata?.actionable === true && !item.path.includes("://");
}

function summarizeReport(report) {
  const grouped = new Map(); const actionableTotals = {};
  for (const item of report.items || []) {
    const key = `${item.classification}\u0000${item.category}`;
    const current = grouped.get(key) || { classification: item.classification, category: item.category, size: 0, count: 0, actionable_size: 0, actionable_count: 0 };
    current.size += Number(item.size || 0); current.count += 1;
    if (item.metadata?.actionable !== false && item.classification !== "PROTECTED") {
      current.actionable_size += Number(item.size || 0); current.actionable_count += 1;
      const total = actionableTotals[item.classification] || { size: 0, count: 0 };
      total.size += Number(item.size || 0); total.count += 1; actionableTotals[item.classification] = total;
    }
    grouped.set(key, current);
  }
  return {
    generated_at: report.generated_at, platform: report.platform || {}, storage: report.storage || {}, home_size: report.home_size,
    totals: report.totals || ["SAFE", "REVIEW", "PROTECTED"].reduce((totals, kind) => {
      totals[kind] = (report.items || []).filter((item) => item.classification === kind).reduce((sum, item) => sum + Number(item.size || 0), 0); return totals;
    }, {}),
    actionable_totals: actionableTotals, home_breakdown: report.home_breakdown || [], notices: report.notices || [], errors: report.errors || [], categories: [...grouped.values()],
  };
}

function categoriesFor(classification) {
  let categories = (state.summary?.categories || []).filter((row) => row.classification === classification);
  if (state.developerMode) categories = categories.filter((row) => /developer|docker|xcode|gradle|npm|python|homebrew/i.test(row.category));
  return categories.sort((a, b) => b.size - a.size);
}

function renderSummary() {
  const summary = state.summary; if (!summary) return;
  const storage = summary.storage || {}; const capacity = Number(storage.capacity || 0), used = Number(storage.used || 0), available = Number(storage.available || 0);
  const ratio = capacity ? Math.min(1, used / capacity) : 0;
  $("#available-amount").textContent = formatBytes(available); $("#used-label").textContent = `${formatBytes(used)} usado`; $("#capacity-label").textContent = `${formatBytes(capacity)} total`;
  $("#capacity-fill").style.width = `${ratio * 100}%`; $("#storage-orbit").style.setProperty("--used-angle", `${ratio * 360}deg`);
  $("#storage-orbit").setAttribute("aria-label", `${(ratio * 100).toFixed(1)} por ciento utilizado`);
  $("#health-label").textContent = ratio > 0.92 ? "Espacio muy limitado" : ratio > 0.8 ? "Conviene revisar el espacio" : "Almacenamiento saludable";
  $("#storage-headline").textContent = ratio > 0.92 ? "Tu disco está casi lleno. Revisemos sin poner tus datos en riesgo." : "Entiende qué ocupa espacio antes de tocar nada.";
  for (const kind of ["SAFE", "REVIEW", "PROTECTED"]) {
    $("#" + kind.toLowerCase() + "-total").textContent = formatBytes(Number(summary.totals?.[kind] || 0));
    const count = (summary.categories || []).filter((row) => row.classification === kind).reduce((sum, row) => sum + Number(row.count || 0), 0);
    $("#" + kind.toLowerCase() + "-nav-count").textContent = compactNumber(count);
  }
  renderTopCategories(); renderHomeLocations();
  const generated = summary.generated_at ? new Date(summary.generated_at) : null;
  $("#scan-status-label").textContent = generated && !Number.isNaN(generated.valueOf())
    ? `${isTauri ? "Analizado" : "Vista previa"} · ${generated.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" })}`
    : isTauri ? "Listo para analizar" : "Vista previa web";
}

function renderTopCategories() {
  const container = $("#top-categories"); container.replaceChildren();
  const categories = (state.summary.categories || []).filter((row) => row.classification !== "PROTECTED").sort((a, b) => b.size - a.size).slice(0, 5);
  for (const row of categories) {
    const button = createElement("button", "category-row"); button.type = "button";
    const symbol = createElement("span", "mini-symbol", row.category.trim().charAt(0).toUpperCase());
    if (row.classification === "SAFE") { symbol.style.color = "var(--safe)"; symbol.style.background = "var(--safe-soft)"; }
    const names = createElement("span", "category-name"); names.append(createElement("strong", "", row.category), createElement("span", "", `${row.count.toLocaleString("es-MX")} elemento${row.count === 1 ? "" : "s"}`));
    button.append(symbol, names, createElement("strong", "category-size", formatBytes(row.size)), createElement("span", "chevron", "›"));
    button.addEventListener("click", () => openBrowser(row.classification, row.category)); container.append(button);
  }
}

function renderHomeLocations() {
  const container = $("#home-locations"); container.replaceChildren(); const rows = (state.summary.home_breakdown || []).slice(0, 6);
  const max = Math.max(...rows.map((row) => Number(row.size || 0)), 1);
  for (const row of rows) {
    const wrapper = createElement("div", "location-row"), meta = createElement("div", "location-meta"), track = createElement("div", "location-track"), fill = document.createElement("span");
    meta.append(createElement("span", "", homePath(row.path)), createElement("strong", "", formatBytes(row.size))); fill.style.width = `${Math.max(3, Number(row.size || 0) / max * 100)}%`;
    track.append(fill); wrapper.append(meta, track); container.append(wrapper);
  }
}

async function loadItems({ append = false } = {}) {
  if (state.loading) return; state.loading = true;
  try {
    const result = await dataSource.listItems({ classification: state.classification, category: state.developerMode ? "__developer__" : state.category || null, query: state.query || null, offset: state.offset, limit: state.limit });
    state.totalResults = result.total; state.loadedItems = append ? state.loadedItems.concat(result.items) : result.items; renderItems(result.items, append);
    const shown = Math.min(state.offset + result.items.length, result.total); $("#result-count").textContent = `${shown.toLocaleString("es-MX")} de ${result.total.toLocaleString("es-MX")}`;
    $("#load-more").classList.toggle("visible", shown < result.total); updateSelectionBar();
  } catch (error) { showToast(String(error), true); } finally { state.loading = false; }
}

function renderItems(items, append) {
  const container = $("#results-list"); if (!append) container.replaceChildren();
  if (!append && !items.length) { container.append(createElement("div", "empty-state", "No hay elementos que coincidan con estos filtros.")); return; }
  for (const item of items) {
    const row = createElement("div", "result-row"), selectCell = createElement("span", "select-cell");
    if (itemActionable(item)) {
      const checkbox = document.createElement("input"); checkbox.type = "checkbox"; checkbox.checked = state.selected.has(item.path); checkbox.setAttribute("aria-label", `Seleccionar ${homePath(item.path)}`);
      checkbox.addEventListener("change", () => toggleSelection(item, checkbox.checked)); selectCell.append(checkbox);
    } else {
      selectCell.textContent = item.classification === "PROTECTED" || item.metadata?.actionable === false ? "⌁" : "";
      selectCell.title = item.metadata?.actionable === false ? "Solo informativo; no hay una acción directa segura" : "";
    }
    const modified = item.mtime ? ` · Modificado ${new Date(item.mtime).toLocaleDateString("es-MX")}` : "";
    const action = item.proposed_action ? ` · Acción: ${item.proposed_action}` : "";
    const detail = `${item.reason || "Sin detalles adicionales"}${modified}${action}`;
    const pathCell = createElement("div", "path-cell"), path = createElement("strong", "", homePath(item.path)), reason = createElement("span", "", detail);
    path.title = item.path; reason.title = detail; pathCell.append(path, reason);
    const tag = createElement("span", "tag", item.category), size = createElement("span", "size-cell", formatBytes(item.size));
    const reveal = createElement("button", "reveal-button"); reveal.type = "button"; reveal.title = isTauri ? "Mostrar en Finder" : "Copiar ruta"; reveal.setAttribute("aria-label", reveal.title);
    reveal.innerHTML = '<svg viewBox="0 0 24 24"><path d="M4 7.5h6l2 2h8v9.5H4V7.5Z"/><path d="M4 10h16"/></svg>';
    reveal.disabled = item.path.includes("://"); reveal.addEventListener("click", () => revealItem(item.path)); row.append(selectCell, pathCell, tag, size, reveal); container.append(row);
  }
}

function toggleSelection(item, checked) {
  if (checked && state.selected.size >= 500) { showToast("Por seguridad, cada operación admite como máximo 500 elementos REVIEW.", true); renderItems(state.loadedItems, false); return; }
  if (checked) state.selected.set(item.path, item); else state.selected.delete(item.path); updateSelectionBar();
}

function updateSelectionBar() {
  const review = state.classification === "REVIEW" && state.reportValid, count = state.selected.size;
  const size = [...state.selected.values()].reduce((sum, item) => sum + Number(item.size || 0), 0);
  $("#selection-bar").hidden = !review || count === 0; $("#selection-count").textContent = `${count.toLocaleString("es-MX")} seleccionado${count === 1 ? "" : "s"}`; $("#selection-size").textContent = `${formatBytes(size)} estimados`;
  const visible = state.loadedItems.filter(itemActionable), selectedVisible = visible.filter((item) => state.selected.has(item.path)).length; const master = $("#select-visible");
  master.hidden = !review; master.checked = visible.length > 0 && selectedVisible === visible.length; master.indeterminate = selectedVisible > 0 && selectedVisible < visible.length; master.disabled = !visible.length;
  const hasDirectory = [...state.selected.values()].some((item) => item.metadata?.object_type !== "file");
  $("#delete-selection").disabled = hasDirectory; $("#delete-selection").title = hasDirectory ? "Los directorios REVIEW solo pueden moverse a la Papelera" : "Requiere escribir ELIMINAR";
}

async function revealItem(path) {
  try { if (isTauri) { await invoke("reveal_path", { path }); showToast("Mostrado en Finder"); } else { await navigator.clipboard.writeText(path); showToast("Ruta copiada"); } }
  catch (error) { showToast(String(error), true); }
}

function openBrowser(classification, category = "", developerMode = false) {
  state.classification = classification; state.category = category; state.developerMode = developerMode; state.query = ""; state.offset = 0; state.loadedItems = [];
  $("#item-search").value = ""; $("#overview-view").classList.remove("active-view"); $("#browser-view").classList.add("active-view"); const meta = classifyMeta(classification);
  $("#browser-symbol").className = `category-symbol ${meta.className}`; $("#browser-symbol").innerHTML = iconSvg(classification); $("#browser-eyebrow").textContent = developerMode ? "ALMACENAMIENTO DE DESARROLLO" : meta.eyebrow;
  $("#browser-title").textContent = developerMode ? "Entornos y artefactos" : category || meta.title; $("#browser-subtitle").textContent = developerMode ? "Selecciona manualmente; los directorios solo se mueven a la Papelera." : meta.subtitle;
  const categories = categoriesFor(classification); const total = developerMode ? categories.reduce((sum, row) => sum + Number(row.size || 0), 0) : category ? Number(categories.find((row) => row.category === category)?.size || 0) : Number(state.summary.totals?.[classification] || 0);
  $("#browser-total").textContent = formatBytes(total); populateCategoryFilter(categories, category, developerMode); $("#page-eyebrow").textContent = developerMode ? "DESARROLLO" : classification; $("#page-title").textContent = developerMode ? "Espacio que tus herramientas pueden reconstruir." : meta.title;
  const safePlan = state.summary?.actionable_totals?.SAFE || { count: 0, size: 0 }; $("#clean-safe-button").hidden = classification !== "SAFE" || !safePlan.count; $("#clean-safe-button").disabled = !state.reportValid;
  updateActiveNav(developerMode ? "developer" : classification); loadItems();
}

function showOverview() {
  state.developerMode = false; $("#browser-view").classList.remove("active-view"); $("#overview-view").classList.add("active-view"); $("#page-eyebrow").textContent = "ALMACENAMIENTO"; $("#page-title").textContent = "Tu Mac, con claridad."; updateActiveNav("overview");
}

function populateCategoryFilter(categories, selected, developerMode) {
  const select = $("#category-filter"); select.replaceChildren(); const all = createElement("option", "", developerMode ? "Todas las herramientas" : "Todas las categorías"); all.value = developerMode ? "__developer__" : ""; select.append(all);
  for (const row of categories) { const option = createElement("option", "", row.category); option.value = row.category; select.append(option); } select.value = developerMode ? "__developer__" : selected || "";
}

function updateActiveNav(view) { $$(".nav-item").forEach((button) => button.classList.toggle("active", button.dataset.view === view)); }
function showToast(message, error = false) {
  const toast = $("#toast"); toast.textContent = message; toast.style.background = error ? "rgba(161, 51, 51, .92)" : "rgba(24, 35, 44, .90)"; toast.classList.add("visible"); clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.classList.remove("visible"), 3200);
}

function startScanPresentation() {
  const overlay = $("#scan-overlay"); overlay.hidden = false; const phases = ["Midiendo el almacenamiento sin modificar ningún archivo.", "Revisando cachés antiguas y archivos abiertos.", "Consultando Docker y herramientas de desarrollo.", "Midiendo ubicaciones protegidas solo para estadísticas."];
  let seconds = 0; $("#scan-phase").textContent = phases[0]; $("#scan-elapsed").textContent = "00:00";
  const timer = setInterval(() => { seconds += 1; $("#scan-elapsed").textContent = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`; $("#scan-phase").textContent = phases[Math.min(phases.length - 1, Math.floor(seconds / 25))]; }, 1000);
  return () => { clearInterval(timer); overlay.hidden = true; };
}

async function runScan() {
  if (!isTauri) { showToast("La vista web usa un informe de demostración. Abre la app Tauri para analizar este Mac."); return; }
  const finish = startScanPresentation();
  try { state.summary = await invoke("scan_storage", { developer: true, large: true }); state.reportValid = true; state.selected.clear(); renderSummary(); showOverview(); updateSelectionBar(); showToast("Análisis completado. Ningún archivo fue modificado."); }
  catch (error) { showToast(String(error), true); } finally { finish(); }
}

const dataSource = {
  async listItems(filters) {
    if (isTauri) return invoke("list_items", filters); let items = state.sampleReport?.items || []; items = items.filter((item) => item.classification === filters.classification);
    if (filters.category === "__developer__") items = items.filter((item) => /developer|docker|xcode|gradle|npm|python|homebrew/i.test(item.category)); else if (filters.category) items = items.filter((item) => item.category === filters.category);
    if (filters.query) { const query = filters.query.toLowerCase(); items = items.filter((item) => [item.path, item.reason, item.category].some((text) => String(text || "").toLowerCase().includes(query))); }
    items.sort((a, b) => Number(b.size || 0) - Number(a.size || 0)); return { total: items.length, items: items.slice(filters.offset, filters.offset + filters.limit) };
  },
};

function dialogPreview(items, max = 24, total = items.length) {
  const container = $("#cleanup-preview"); container.replaceChildren();
  for (const item of items.slice(0, max)) { const row = createElement("div", "cleanup-preview-row"); row.append(createElement("span", "", homePath(item.path)), createElement("strong", "", formatBytes(item.size))); container.append(row); }
  if (total > max) container.append(createElement("div", "cleanup-more", `…y ${total - max} elementos más, visibles en la lista de resultados y en el registro de auditoría.`));
}

async function openCleanupDialog(kind) {
  if (!isTauri || !state.reportValid) { showToast("Analiza de nuevo antes de ejecutar una acción.", true); return; }
  let plan;
  if (kind === "safe") {
    const totals = state.summary.actionable_totals?.SAFE || { count: 0, size: 0 }; const previewResult = await dataSource.listItems({ classification: "SAFE", category: null, query: null, offset: 0, limit: 200 });
    const preview = previewResult.items.filter((item) => item.metadata?.actionable !== false);
    plan = { classification: "SAFE", mode: "delete", paths: [], allSafe: true, count: Number(totals.count || 0), size: Number(totals.size || 0), items: preview };
    $("#cleanup-eyebrow").textContent = "PLAN SAFE COMPLETO"; $("#cleanup-title").textContent = "¿Limpiar los elementos regenerables?"; $("#cleanup-description").textContent = "Se eliminarán permanentemente solo archivos antiguos clasificados SAFE y acciones oficiales ya previsualizadas. Cada objeto se revalidará antes de tocarlo.";
  } else {
    const items = [...state.selected.values()], mode = kind === "delete" ? "delete" : "trash";
    plan = { classification: "REVIEW", mode, paths: items.map((item) => item.path), allSafe: false, count: items.length, size: items.reduce((sum, item) => sum + Number(item.size || 0), 0), items };
    $("#cleanup-eyebrow").textContent = mode === "trash" ? "ACCIÓN REVERSIBLE" : "ACCIÓN IRREVERSIBLE"; $("#cleanup-title").textContent = mode === "trash" ? "¿Mover la selección a la Papelera?" : "¿Eliminar permanentemente la selección?";
    $("#cleanup-description").textContent = mode === "trash" ? "Los elementos se moverán atómicamente a tu Papelera. No se copiarán ni borrarán si están en otro sistema de archivos." : "Esta opción no usa la Papelera y solo admite archivos regulares individuales. No se puede deshacer.";
  }
  state.cleanupPlan = plan; state.dialogMode = "confirm"; $("#cleanup-summary").textContent = `${plan.count.toLocaleString("es-MX")} elementos · ${formatBytes(plan.size)} estimados`; dialogPreview(plan.items, 24, plan.count);
  $("#cleanup-ack-row").hidden = kind !== "safe"; $("#cleanup-ack").checked = false; $("#cleanup-phrase-row").hidden = kind !== "delete"; $("#cleanup-phrase").value = "";
  $("#cleanup-cancel").hidden = false; $("#cleanup-cancel").textContent = "Cancelar"; $("#cleanup-confirm").textContent = plan.mode === "trash" ? "Mover a Papelera" : kind === "safe" ? "Limpiar SAFE" : "Eliminar permanentemente";
  updateConfirmButton(); $("#cleanup-dialog").showModal();
  requestAnimationFrame(() => {
    $("#cleanup-dialog").scrollTop = 0;
    $("#cleanup-preview").scrollTop = 0;
  });
}

function updateConfirmButton() {
  const plan = state.cleanupPlan; $("#cleanup-confirm").disabled = !plan || (plan.classification === "SAFE" && !$("#cleanup-ack").checked) || (plan.classification === "REVIEW" && plan.mode === "delete" && $("#cleanup-phrase").value !== "ELIMINAR");
}

async function executeCleanup() {
  if (state.dialogMode === "complete") { $("#cleanup-dialog").close(); await runScan(); return; }
  const plan = state.cleanupPlan;
  const dialog = $("#cleanup-dialog");
  const acknowledged = plan?.classification !== "SAFE" || $("#cleanup-ack").checked;
  const phraseAccepted = plan?.classification !== "REVIEW" || plan?.mode !== "delete" || $("#cleanup-phrase").value === "ELIMINAR";
  if (!plan || !dialog.open || !acknowledged || !phraseAccepted) {
    state.cleanupPlan = null;
    if (dialog.open) dialog.close();
    showToast("Confirmación inválida o caducada. No se ejecutó ninguna acción.", true);
    return;
  }
  dialog.close(); $("#action-overlay").hidden = false;
  try { const record = await invoke("execute_cleanup", { classification: plan.classification, paths: plan.paths, mode: plan.mode, allSafe: plan.allSafe }); state.reportValid = false; state.selected.clear(); updateSelectionBar(); showCompletion(record); }
  catch (error) { showToast(String(error), true); } finally { $("#action-overlay").hidden = true; }
}

function showCompletion(record) {
  state.dialogMode = "complete"; state.cleanupPlan = null; $("#cleanup-eyebrow").textContent = record.failed ? "COMPLETADO CON RECHAZOS" : "ACCIÓN COMPLETADA";
  $("#cleanup-title").textContent = record.failed ? "Algunos elementos se conservaron" : "La comprobación terminó correctamente"; $("#cleanup-description").textContent = `${record.succeeded} acciones completadas y ${record.failed} rechazadas o fallidas. El espacio recuperado se midió en el disco, no se calculó sumando archivos.`;
  $("#cleanup-summary").textContent = `Antes ${formatBytes(record.before_available)} · Después ${formatBytes(record.after_available)} · Recuperado ${formatBytes(record.reclaimed, true)}`;
  const details = (record.failure_details || []).map((item) => ({ path: item.path, size: item.original_size, reason: item.message })); dialogPreview(details); $("#cleanup-preview").append(createElement("div", "audit-path", `${details.length ? "Registro completo" : "Auditoría"}: ${record.audit_path}`));
  $("#cleanup-ack-row").hidden = true; $("#cleanup-phrase-row").hidden = true; $("#cleanup-cancel").hidden = false; $("#cleanup-cancel").textContent = "Cerrar"; $("#cleanup-confirm").disabled = false; $("#cleanup-confirm").textContent = "Analizar de nuevo"; $("#cleanup-dialog").showModal();
}

function bindEvents() {
  $("#scan-button").addEventListener("click", runScan); $$('[data-open-classification]').forEach((button) => button.addEventListener("click", () => openBrowser(button.dataset.openClassification)));
  $$(".nav-item").forEach((button) => button.addEventListener("click", () => { const view = button.dataset.view; if (view === "overview") showOverview(); else if (view === "developer") openBrowser("REVIEW", "", true); else openBrowser(view); }));
  $("#category-filter").addEventListener("change", (event) => { state.category = event.target.value === "__developer__" ? "" : event.target.value; state.developerMode = event.target.value === "__developer__"; state.offset = 0; state.loadedItems = []; loadItems(); });
  let searchTimer; $("#item-search").addEventListener("input", (event) => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { state.query = event.target.value.trim(); state.offset = 0; state.loadedItems = []; loadItems(); }, 180); });
  $("#load-more").addEventListener("click", () => { state.offset += state.limit; loadItems({ append: true }); }); $("#settings-button").addEventListener("click", () => $("#policy-dialog").showModal()); $("#policy-close").addEventListener("click", () => $("#policy-dialog").close());
  $("#select-visible").addEventListener("change", (event) => {
    const visible = state.loadedItems.filter(itemActionable), additions = visible.filter((item) => !state.selected.has(item.path)).length;
    if (event.target.checked && state.selected.size + additions > 500) { event.target.checked = false; showToast("La selección visible superaría el límite de 500 elementos.", true); return; }
    for (const item of visible) { if (event.target.checked) state.selected.set(item.path, item); else state.selected.delete(item.path); } renderItems(state.loadedItems, false); updateSelectionBar();
  });
  $("#clear-selection").addEventListener("click", () => { state.selected.clear(); renderItems(state.loadedItems, false); updateSelectionBar(); }); $("#trash-selection").addEventListener("click", () => openCleanupDialog("trash")); $("#delete-selection").addEventListener("click", () => openCleanupDialog("delete")); $("#clean-safe-button").addEventListener("click", () => openCleanupDialog("safe"));
  $("#cleanup-ack").addEventListener("change", updateConfirmButton); $("#cleanup-phrase").addEventListener("input", updateConfirmButton); $("#cleanup-confirm").addEventListener("click", executeCleanup);
  const closeCleanup = () => {
    $("#cleanup-dialog").close();
    if (state.dialogMode === "confirm") state.cleanupPlan = null;
  };
  $("#cleanup-close").addEventListener("click", closeCleanup); $("#cleanup-cancel").addEventListener("click", closeCleanup);
  $("#cleanup-dialog").addEventListener("close", () => {
    if (state.dialogMode === "confirm") state.cleanupPlan = null;
  });
}

async function initialize() {
  bindEvents(); if (isTauri) { $("#scan-status-label").textContent = "Listo para analizar"; await runScan(); return; }
  try { state.sampleReport = await fetch("sample-report.json").then((response) => { if (!response.ok) throw new Error("No se pudo cargar la demostración"); return response.json(); }); state.summary = summarizeReport(state.sampleReport); state.reportValid = false; renderSummary(); }
  catch (error) { showToast(String(error), true); }
}

initialize();
