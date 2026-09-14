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
  return `${value.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits })} ${units[unit]}`;
}

function compactNumber(number) {
  return new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(number || 0);
}

function homePath(path) {
  const home = state.summary?.home_breakdown?.find((row) => row.path?.includes("/Library"))?.path?.replace(/\/Library$/, "");
  return home && path.startsWith(`${home}/`) ? `~/${path.slice(home.length + 1)}` : path;
}

function classifyMeta(classification) {
  return {
    SAFE: { eyebrow: "REGENERABLE · CONFIRMATION REQUIRED", title: "Safe to clean", subtitle: "Old files under known roots. Inspect every path before confirming.", className: "safe" },
    REVIEW: { eyebrow: "HUMAN DECISION", title: "Requires your review", subtitle: "Nothing is preselected. The recommended action is to move items to Trash.", className: "review" },
    PROTECTED: { eyebrow: "STATISTICS ONLY", title: "Explicitly protected", subtitle: "These locations are measured, but the app refuses to modify them.", className: "protected" },
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

function isDeveloperCategory(category) {
  return /developer|docker|xcode|gradle|npm|pnpm|python|homebrew/i.test(category || "");
}

function isDockerImage(item) {
  return item.metadata?.execution_kind === "docker-image";
}

function displayItemPath(item) {
  if (isDockerImage(item)) return (item.metadata?.docker_tags || []).join(", ") || item.metadata?.docker_id || item.path;
  return homePath(item.path);
}

function itemActionable(item) {
  return item.classification === "REVIEW" && item.metadata?.actionable === true && (!item.path.includes("://") || isDockerImage(item));
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
  if (state.developerMode) categories = categories.filter((row) => isDeveloperCategory(row.category));
  return categories.sort((a, b) => b.size - a.size);
}

function renderSummary() {
  const summary = state.summary; if (!summary) return;
  const storage = summary.storage || {}; const capacity = Number(storage.capacity || 0), used = Number(storage.used || 0), available = Number(storage.available || 0);
  const ratio = capacity ? Math.min(1, used / capacity) : 0;
  $("#available-amount").textContent = formatBytes(available); $("#used-label").textContent = `${formatBytes(used)} used`; $("#capacity-label").textContent = `${formatBytes(capacity)} total`;
  $("#capacity-fill").style.width = `${ratio * 100}%`; $("#storage-orbit").style.setProperty("--used-angle", `${ratio * 360}deg`);
  $("#storage-orbit").setAttribute("aria-label", `${(ratio * 100).toFixed(1)} percent used`);
  $("#health-label").textContent = ratio > 0.92 ? "Very limited space" : ratio > 0.8 ? "Space is worth reviewing" : "Healthy storage";
  $("#storage-headline").textContent = ratio > 0.92 ? "Your disk is almost full. Let’s review it without putting your data at risk." : "Understand what is using space before changing anything.";
  for (const kind of ["SAFE", "REVIEW", "PROTECTED"]) {
    $("#" + kind.toLowerCase() + "-total").textContent = formatBytes(Number(summary.totals?.[kind] || 0));
    const count = (summary.categories || []).filter((row) => row.classification === kind).reduce((sum, row) => sum + Number(row.count || 0), 0);
    $("#" + kind.toLowerCase() + "-nav-count").textContent = compactNumber(count);
  }
  renderTopCategories(); renderHomeLocations(); renderDeveloperView();
  const generated = summary.generated_at ? new Date(summary.generated_at) : null;
  $("#scan-status-label").textContent = generated && !Number.isNaN(generated.valueOf())
    ? `${isTauri ? "Scanned" : "Preview"} · ${generated.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })}`
    : isTauri ? "Ready to scan" : "Web preview";
}

function renderTopCategories() {
  const container = $("#top-categories"); container.replaceChildren();
  const categories = (state.summary.categories || []).filter((row) => row.classification !== "PROTECTED").sort((a, b) => b.size - a.size).slice(0, 5);
  for (const row of categories) {
    const button = createElement("button", "category-row"); button.type = "button";
    const symbol = createElement("span", "mini-symbol", row.category.trim().charAt(0).toUpperCase());
    if (row.classification === "SAFE") { symbol.style.color = "var(--safe)"; symbol.style.background = "var(--safe-soft)"; }
    const names = createElement("span", "category-name"); names.append(createElement("strong", "", row.category), createElement("span", "", `${row.count.toLocaleString("en-US")} item${row.count === 1 ? "" : "s"}`));
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

function renderDeveloperView() {
  if (!state.summary) return;
  const categories = (state.summary.categories || []).filter((row) => isDeveloperCategory(row.category));
  const docker = categories.filter((row) => /^Docker\s+—/i.test(row.category));
  const tooling = categories.filter((row) => !/^Docker\s+—/i.test(row.category)).sort((a, b) => b.size - a.size);
  const total = categories.reduce((sum, row) => sum + Number(row.size || 0), 0);
  const itemCount = categories.reduce((sum, row) => sum + Number(row.count || 0), 0);
  const dockerTotal = docker.reduce((sum, row) => sum + Number(row.size || 0), 0);
  const dockerCount = docker.reduce((sum, row) => sum + Number(row.count || 0), 0);
  $("#developer-total").textContent = formatBytes(total);
  $("#developer-item-count").textContent = `${itemCount.toLocaleString("en-US")} scanned item${itemCount === 1 ? "" : "s"}`;
  $("#docker-total").textContent = formatBytes(dockerTotal);
  $("#docker-item-count").textContent = docker.length ? `${dockerCount.toLocaleString("en-US")} resource${dockerCount === 1 ? "" : "s"}` : "Not detected";

  const dockerContainer = $("#docker-resources"); dockerContainer.replaceChildren();
  if (!docker.length) dockerContainer.append(createElement("div", "developer-empty", "Docker did not report any local resources in this scan."));
  for (const row of docker.sort((a, b) => b.size - a.size)) {
    const button = createElement("button", "docker-resource"); button.type = "button";
    const name = row.category.replace(/^Docker\s+—\s*/i, "");
    const detail = row.actionable_count ? `${row.actionable_count.toLocaleString("en-US")} can be reviewed for removal` : `${row.count.toLocaleString("en-US")} item${row.count === 1 ? "" : "s"} · Docker-managed`;
    button.append(createElement("span", "", name), createElement("strong", "", formatBytes(row.size)), createElement("small", "", detail));
    button.addEventListener("click", () => openBrowser(row.classification, row.category, true)); dockerContainer.append(button);
  }

  const toolsContainer = $("#developer-tools"); toolsContainer.replaceChildren();
  if (!tooling.length) toolsContainer.append(createElement("div", "developer-empty", "No supported SDK, dependency, or package-cache storage was found."));
  for (const row of tooling.slice(0, 6)) {
    const button = createElement("button", "developer-tool"); button.type = "button";
    const icon = createElement("span", "developer-tool-icon", row.category.replace(/^Developer\s+—\s*/i, "").slice(0, 2).toUpperCase());
    const name = createElement("span", "developer-tool-name");
    const action = row.classification === "SAFE" ? "Manager or confirmed cleanup" : row.actionable_count ? "Review individually" : "Review only";
    name.append(createElement("strong", "", row.category), createElement("span", "", `${row.count.toLocaleString("en-US")} item${row.count === 1 ? "" : "s"} · ${action}`));
    button.append(icon, name, createElement("strong", "developer-tool-size", formatBytes(row.size)), createElement("span", "developer-tool-chevron", "›"));
    button.addEventListener("click", () => openBrowser(row.classification, row.category, true)); toolsContainer.append(button);
  }
}

async function loadItems({ append = false } = {}) {
  if (state.loading) return; state.loading = true;
  try {
    const category = state.category || (state.developerMode ? "__developer__" : null);
    const result = await dataSource.listItems({ classification: state.classification, category, query: state.query || null, offset: state.offset, limit: state.limit });
    state.totalResults = result.total; state.loadedItems = append ? state.loadedItems.concat(result.items) : result.items; renderItems(result.items, append);
    const shown = Math.min(state.offset + result.items.length, result.total); $("#result-count").textContent = `${shown.toLocaleString("en-US")} of ${result.total.toLocaleString("en-US")}`;
    $("#load-more").classList.toggle("visible", shown < result.total); updateSelectionBar();
  } catch (error) { showToast(String(error), true); } finally { state.loading = false; }
}

function renderItems(items, append) {
  const container = $("#results-list"); if (!append) container.replaceChildren();
  if (!append && !items.length) { container.append(createElement("div", "empty-state", "No items match these filters.")); return; }
  for (const item of items) {
    const row = createElement("div", "result-row"), selectCell = createElement("span", "select-cell");
    if (itemActionable(item)) {
      const checkbox = document.createElement("input"); checkbox.type = "checkbox"; checkbox.checked = state.selected.has(item.path); checkbox.setAttribute("aria-label", `Select ${displayItemPath(item)}`);
      checkbox.addEventListener("change", () => toggleSelection(item, checkbox.checked)); selectCell.append(checkbox);
    } else {
      selectCell.textContent = item.classification === "PROTECTED" || item.metadata?.actionable === false ? "⌁" : "";
      selectCell.title = item.metadata?.actionable === false ? "Informational only; no safe direct action is available" : "";
    }
    const modified = item.mtime ? ` · Modified ${new Date(item.mtime).toLocaleDateString("en-US")}` : "";
    const action = item.proposed_action ? ` · Action: ${item.proposed_action}` : "";
    const detail = `${item.reason || "No additional details"}${modified}${action}`;
    const pathCell = createElement("div", "path-cell"), path = createElement("strong", "", displayItemPath(item)), reason = createElement("span", "", detail);
    path.title = item.path; reason.title = detail; pathCell.append(path, reason);
    const tag = createElement("span", "tag", item.category), size = createElement("span", "size-cell", formatBytes(item.size));
    const reveal = createElement("button", "reveal-button"); reveal.type = "button"; reveal.title = isTauri ? "Show in Finder" : "Copy path"; reveal.setAttribute("aria-label", reveal.title);
    reveal.innerHTML = '<svg viewBox="0 0 24 24"><path d="M4 7.5h6l2 2h8v9.5H4V7.5Z"/><path d="M4 10h16"/></svg>';
    reveal.disabled = item.path.includes("://"); reveal.addEventListener("click", () => revealItem(item.path)); row.append(selectCell, pathCell, tag, size, reveal); container.append(row);
  }
}

function toggleSelection(item, checked) {
  if (checked && state.selected.size >= 500) { showToast("For safety, each operation supports at most 500 REVIEW items.", true); renderItems(state.loadedItems, false); return; }
  if (checked) state.selected.set(item.path, item); else state.selected.delete(item.path); updateSelectionBar();
}

function updateSelectionBar() {
  const review = state.classification === "REVIEW" && state.reportValid, count = state.selected.size;
  const size = [...state.selected.values()].reduce((sum, item) => sum + Number(item.size || 0), 0);
  $("#selection-bar").hidden = !review || count === 0; $("#selection-count").textContent = `${count.toLocaleString("en-US")} selected`; $("#selection-size").textContent = `${formatBytes(size)} estimated`;
  const visible = state.loadedItems.filter(itemActionable), selectedVisible = visible.filter((item) => state.selected.has(item.path)).length; const master = $("#select-visible");
  master.hidden = !review; master.checked = visible.length > 0 && selectedVisible === visible.length; master.indeterminate = selectedVisible > 0 && selectedVisible < visible.length; master.disabled = !visible.length;
  const selected = [...state.selected.values()]; const hasDocker = selected.some(isDockerImage), hasFilesystem = selected.some((item) => !isDockerImage(item));
  const hasDirectory = selected.some((item) => !isDockerImage(item) && item.metadata?.object_type && item.metadata.object_type !== "file");
  const trash = $("#trash-selection"), remove = $("#delete-selection");
  trash.disabled = hasDocker; trash.title = hasDocker ? "Docker resources are removed through Docker, not moved to Trash" : "Move selected files or directories to Trash";
  remove.textContent = hasDocker && !hasFilesystem ? "Remove from Docker…" : "Delete permanently…";
  remove.disabled = hasDirectory || (hasDocker && hasFilesystem);
  remove.title = hasDocker && hasFilesystem ? "Select Docker images separately from filesystem items" : hasDirectory ? "REVIEW directories can only be moved to Trash" : hasDocker ? "Docker will refuse images that are in use" : "Requires typing DELETE";
}

async function revealItem(path) {
  try { if (isTauri) { await invoke("reveal_path", { path }); showToast("Shown in Finder"); } else { await navigator.clipboard.writeText(path); showToast("Path copied"); } }
  catch (error) { showToast(String(error), true); }
}

function openBrowser(classification, category = "", developerMode = false) {
  state.classification = classification; state.category = category; state.developerMode = developerMode; state.query = ""; state.offset = 0; state.loadedItems = [];
  $("#item-search").value = ""; $("#overview-view").classList.remove("active-view"); $("#developer-view").classList.remove("active-view"); $("#browser-view").classList.add("active-view"); const meta = classifyMeta(classification);
  $("#browser-symbol").className = `category-symbol ${meta.className}`; $("#browser-symbol").innerHTML = iconSvg(classification); $("#browser-eyebrow").textContent = developerMode ? "DEVELOPMENT STORAGE" : meta.eyebrow;
  $("#browser-title").textContent = category || (developerMode ? "Environments and artifacts" : meta.title); $("#browser-subtitle").textContent = developerMode ? "Review each resource before acting. Docker images are removed only through Docker." : meta.subtitle;
  const categories = categoriesFor(classification); const total = category ? Number(categories.find((row) => row.category === category)?.size || 0) : developerMode ? categories.reduce((sum, row) => sum + Number(row.size || 0), 0) : Number(state.summary.totals?.[classification] || 0);
  $("#browser-total").textContent = formatBytes(total); populateCategoryFilter(categories, category, developerMode); $("#page-eyebrow").textContent = developerMode ? "DEVELOPMENT" : classification; $("#page-title").textContent = developerMode ? "Space your tools can rebuild." : meta.title;
  const safePlan = state.summary?.actionable_totals?.SAFE || { count: 0, size: 0 }; $("#clean-safe-button").hidden = classification !== "SAFE" || !safePlan.count; $("#clean-safe-button").disabled = !state.reportValid;
  syncDeveloperSwitch(developerMode); updateActiveNav(developerMode ? "developer" : classification); loadItems();
}

function showOverview() {
  state.developerMode = false; $("#browser-view").classList.remove("active-view"); $("#developer-view").classList.remove("active-view"); $("#overview-view").classList.add("active-view"); $("#page-eyebrow").textContent = "STORAGE"; $("#page-title").textContent = "Your Mac, made clear."; syncDeveloperSwitch(false); updateActiveNav("overview");
}

function syncDeveloperSwitch(enabled) {
  $("#developer-mode-switch").checked = enabled; $(".developer-toggle").classList.toggle("enabled", enabled);
  try { localStorage.setItem("mac-cleaner-developer-view", String(enabled)); } catch { /* Storage can be unavailable in private web views. */ }
}

function showDeveloperView() {
  state.developerMode = true; state.classification = "REVIEW"; state.category = ""; state.selected.clear();
  $("#overview-view").classList.remove("active-view"); $("#browser-view").classList.remove("active-view"); $("#developer-view").classList.add("active-view");
  $("#page-eyebrow").textContent = "DEVELOPMENT"; $("#page-title").textContent = "Storage for the tools you build with."; syncDeveloperSwitch(true); updateActiveNav("developer"); renderDeveloperView(); updateSelectionBar();
}

function populateCategoryFilter(categories, selected, developerMode) {
  const select = $("#category-filter"); select.replaceChildren(); const all = createElement("option", "", developerMode ? "All tools" : "All categories"); all.value = developerMode ? "__developer__" : ""; select.append(all);
  for (const row of categories) { const option = createElement("option", "", row.category); option.value = row.category; select.append(option); } select.value = selected || (developerMode ? "__developer__" : "");
}

function updateActiveNav(view) { $$(".nav-item").forEach((button) => button.classList.toggle("active", button.dataset.view === view)); }
function showToast(message, error = false) {
  const toast = $("#toast"); toast.textContent = message; toast.style.background = error ? "rgba(161, 51, 51, .92)" : "rgba(24, 35, 44, .90)"; toast.classList.add("visible"); clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.classList.remove("visible"), 3200);
}

function startScanPresentation() {
  const overlay = $("#scan-overlay"); overlay.hidden = false; const phases = ["Measuring storage without modifying any files.", "Reviewing old caches and open files.", "Checking Docker and development tools.", "Measuring protected locations for statistics only."];
  let seconds = 0; $("#scan-phase").textContent = phases[0]; $("#scan-elapsed").textContent = "00:00";
  const timer = setInterval(() => { seconds += 1; $("#scan-elapsed").textContent = `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`; $("#scan-phase").textContent = phases[Math.min(phases.length - 1, Math.floor(seconds / 25))]; }, 1000);
  return () => { clearInterval(timer); overlay.hidden = true; };
}

async function runScan() {
  if (!isTauri) { showToast("The web view uses a demo report. Open the Tauri app to scan this Mac."); return; }
  const returnToDeveloperView = state.developerMode;
  const finish = startScanPresentation();
  try { state.summary = await invoke("scan_storage", { developer: true, large: true }); state.reportValid = true; state.selected.clear(); renderSummary(); if (returnToDeveloperView) showDeveloperView(); else showOverview(); updateSelectionBar(); showToast("Scan complete. No files were modified."); }
  catch (error) { showToast(String(error), true); } finally { finish(); }
}

const dataSource = {
  async listItems(filters) {
    if (isTauri) return invoke("list_items", filters); let items = state.sampleReport?.items || []; items = items.filter((item) => item.classification === filters.classification);
    if (filters.category === "__developer__") items = items.filter((item) => isDeveloperCategory(item.category)); else if (filters.category) items = items.filter((item) => item.category === filters.category);
    if (filters.query) { const query = filters.query.toLowerCase(); items = items.filter((item) => [item.path, item.reason, item.category].some((text) => String(text || "").toLowerCase().includes(query))); }
    items.sort((a, b) => Number(b.size || 0) - Number(a.size || 0)); return { total: items.length, items: items.slice(filters.offset, filters.offset + filters.limit) };
  },
};

function dialogPreview(items, max = 24, total = items.length) {
  const container = $("#cleanup-preview"); container.replaceChildren();
  for (const item of items.slice(0, max)) { const row = createElement("div", "cleanup-preview-row"); row.append(createElement("span", "", homePath(item.path)), createElement("strong", "", formatBytes(item.size))); container.append(row); }
  if (total > max) container.append(createElement("div", "cleanup-more", `…and ${total - max} more items, visible in the results list and audit log.`));
}

async function openCleanupDialog(kind) {
  if (!isTauri || !state.reportValid) { showToast("Scan again before performing an action.", true); return; }
  let plan;
  if (kind === "safe") {
    const totals = state.summary.actionable_totals?.SAFE || { count: 0, size: 0 }; const previewResult = await dataSource.listItems({ classification: "SAFE", category: null, query: null, offset: 0, limit: 200 });
    const preview = previewResult.items.filter((item) => item.metadata?.actionable !== false);
    plan = { classification: "SAFE", mode: "delete", paths: [], allSafe: true, count: Number(totals.count || 0), size: Number(totals.size || 0), items: preview };
    $("#cleanup-eyebrow").textContent = "FULL SAFE PLAN"; $("#cleanup-title").textContent = "Clean regenerable items?"; $("#cleanup-description").textContent = "Only old files classified as SAFE and already-previewed official actions will be permanently removed. Every object will be revalidated before it is touched.";
  } else {
    const items = [...state.selected.values()], mode = kind === "delete" ? "delete" : "trash";
    plan = { classification: "REVIEW", mode, paths: items.map((item) => item.path), allSafe: false, count: items.length, size: items.reduce((sum, item) => sum + Number(item.size || 0), 0), items };
    const dockerOnly = items.length > 0 && items.every(isDockerImage);
    $("#cleanup-eyebrow").textContent = dockerOnly ? "DOCKER REMOVAL" : mode === "trash" ? "REVERSIBLE ACTION" : "IRREVERSIBLE ACTION";
    $("#cleanup-title").textContent = dockerOnly ? "Remove selected Docker images?" : mode === "trash" ? "Move selection to Trash?" : "Delete selection permanently?";
    $("#cleanup-description").textContent = dockerOnly ? "Each image is checked again and removed through Docker without force. Docker refuses images that are still used by a container. This cannot be undone." : mode === "trash" ? "Items will be moved atomically to your Trash. They will not be copied or deleted across file systems." : "This option bypasses Trash and only supports individual regular files. It cannot be undone.";
  }
  state.cleanupPlan = plan; state.dialogMode = "confirm"; $("#cleanup-summary").textContent = `${plan.count.toLocaleString("en-US")} items · ${formatBytes(plan.size)} estimated`; dialogPreview(plan.items, 24, plan.count);
  $("#cleanup-ack-row").hidden = kind !== "safe"; $("#cleanup-ack").checked = false; $("#cleanup-phrase-row").hidden = kind !== "delete"; $("#cleanup-phrase").value = "";
  $("#cleanup-cancel").hidden = false; $("#cleanup-cancel").textContent = "Cancel"; $("#cleanup-confirm").textContent = plan.mode === "trash" ? "Move to Trash" : kind === "safe" ? "Clean SAFE" : "Delete permanently";
  updateConfirmButton(); $("#cleanup-dialog").showModal();
  requestAnimationFrame(() => {
    $("#cleanup-dialog").scrollTop = 0;
    $("#cleanup-preview").scrollTop = 0;
  });
}

function updateConfirmButton() {
  const plan = state.cleanupPlan; $("#cleanup-confirm").disabled = !plan || (plan.classification === "SAFE" && !$("#cleanup-ack").checked) || (plan.classification === "REVIEW" && plan.mode === "delete" && $("#cleanup-phrase").value !== "DELETE");
}

async function executeCleanup() {
  if (state.dialogMode === "complete") { $("#cleanup-dialog").close(); await runScan(); return; }
  const plan = state.cleanupPlan;
  const dialog = $("#cleanup-dialog");
  const acknowledged = plan?.classification !== "SAFE" || $("#cleanup-ack").checked;
  const phraseAccepted = plan?.classification !== "REVIEW" || plan?.mode !== "delete" || $("#cleanup-phrase").value === "DELETE";
  if (!plan || !dialog.open || !acknowledged || !phraseAccepted) {
    state.cleanupPlan = null;
    if (dialog.open) dialog.close();
    showToast("Confirmation is invalid or expired. No action was performed.", true);
    return;
  }
  dialog.close(); $("#action-overlay").hidden = false;
  try { const record = await invoke("execute_cleanup", { classification: plan.classification, paths: plan.paths, mode: plan.mode, allSafe: plan.allSafe }); state.reportValid = false; state.selected.clear(); updateSelectionBar(); showCompletion(record); }
  catch (error) { showToast(String(error), true); } finally { $("#action-overlay").hidden = true; }
}

function showCompletion(record) {
  state.dialogMode = "complete"; state.cleanupPlan = null; $("#cleanup-eyebrow").textContent = record.failed ? "COMPLETED WITH REFUSALS" : "ACTION COMPLETED";
  $("#cleanup-title").textContent = record.failed ? "Some items were kept" : "The check completed successfully"; $("#cleanup-description").textContent = `${record.succeeded} actions completed and ${record.failed} refused or failed. Reclaimed space was measured on disk, not calculated by adding file estimates.`;
  $("#cleanup-summary").textContent = `Before ${formatBytes(record.before_available)} · After ${formatBytes(record.after_available)} · Reclaimed ${formatBytes(record.reclaimed, true)}`;
  const details = (record.failure_details || []).map((item) => ({ path: item.path, size: item.original_size, reason: item.message })); dialogPreview(details); $("#cleanup-preview").append(createElement("div", "audit-path", `${details.length ? "Full log" : "Audit"}: ${record.audit_path}`));
  $("#cleanup-ack-row").hidden = true; $("#cleanup-phrase-row").hidden = true; $("#cleanup-cancel").hidden = false; $("#cleanup-cancel").textContent = "Close"; $("#cleanup-confirm").disabled = false; $("#cleanup-confirm").textContent = "Scan again"; $("#cleanup-dialog").showModal();
}

function bindEvents() {
  $("#scan-button").addEventListener("click", runScan); $$('[data-open-classification]').forEach((button) => button.addEventListener("click", () => openBrowser(button.dataset.openClassification)));
  $$(".nav-item").forEach((button) => button.addEventListener("click", () => { const view = button.dataset.view; if (view === "overview") showOverview(); else openBrowser(view); }));
  $("#developer-mode-switch").addEventListener("change", (event) => { if (event.target.checked) showDeveloperView(); else showOverview(); });
  $("#developer-browse-all").addEventListener("click", () => openBrowser("REVIEW", "", true));
  $("#category-filter").addEventListener("change", (event) => { state.category = event.target.value === "__developer__" ? "" : event.target.value; state.offset = 0; state.loadedItems = []; loadItems(); });
  let searchTimer; $("#item-search").addEventListener("input", (event) => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { state.query = event.target.value.trim(); state.offset = 0; state.loadedItems = []; loadItems(); }, 180); });
  $("#load-more").addEventListener("click", () => { state.offset += state.limit; loadItems({ append: true }); }); $("#settings-button").addEventListener("click", () => $("#policy-dialog").showModal()); $("#policy-close").addEventListener("click", () => $("#policy-dialog").close());
  $("#select-visible").addEventListener("change", (event) => {
    const visible = state.loadedItems.filter(itemActionable), additions = visible.filter((item) => !state.selected.has(item.path)).length;
    if (event.target.checked && state.selected.size + additions > 500) { event.target.checked = false; showToast("The visible selection would exceed the 500-item limit.", true); return; }
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
  bindEvents(); try { state.developerMode = localStorage.getItem("mac-cleaner-developer-view") === "true"; } catch { state.developerMode = false; }
  if (isTauri) { $("#scan-status-label").textContent = "Ready to scan"; await runScan(); return; }
  try { state.sampleReport = await fetch("sample-report.json").then((response) => { if (!response.ok) throw new Error("Could not load the demo report"); return response.json(); }); state.summary = summarizeReport(state.sampleReport); state.reportValid = false; renderSummary(); if (state.developerMode) showDeveloperView(); else showOverview(); }
  catch (error) { showToast(String(error), true); }
}

initialize();
