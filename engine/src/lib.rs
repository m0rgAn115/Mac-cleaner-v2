use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    ffi::CString,
    fs::{self, Metadata},
    hash::{Hash, Hasher},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread::{self, JoinHandle},
};

const VERSION: u32 = 1;
const MAX_REQUEST: usize = 16 * 1024 * 1024;
mod targets;
fn default_true() -> bool {
    true
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Target {
    path: PathBuf,
    category: String,
    owner: Option<String>,
    autoselected: bool,
    detail: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Rules {
    pub version: u32,
    #[serde(default)]
    pub paths: Vec<PathBuf>,
    #[serde(default)]
    pub names: Vec<String>,
    #[serde(default)]
    pub bundle_ids: Vec<String>,
}
impl Rules {
    fn valid(&self) -> bool {
        self.version == VERSION
            && self.paths.iter().all(|p| {
                p.is_absolute() && !p.components().any(|c| matches!(c, Component::ParentDir))
            })
    }
    fn normalize_paths(&mut self) {
        // Foundation and POSIX may spell the same temporary path as /var or /private/var.
        let aliases: Vec<_> = self
            .paths
            .iter()
            .filter_map(|p| fs::canonicalize(p).ok())
            .collect();
        self.paths.extend(aliases);
        self.paths.sort();
        self.paths.dedup();
    }
    fn ignored(&self, path: &Path, owner: Option<&str>) -> bool {
        self.paths.iter().any(|p| path.starts_with(p))
            || path
                .file_name()
                .is_some_and(|n| self.names.iter().any(|s| n == s.as_str()))
            || owner.is_some_and(|b| self.bundle_ids.iter().any(|s| s == b))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    home: PathBuf,
    rules: Rules,
    #[serde(default)]
    installed_bundle_ids: HashSet<String>,
    #[serde(default)]
    container_owners: BTreeMap<String, String>,
    #[serde(default)]
    cache_owners: BTreeMap<String, String>,
    #[serde(default)]
    targets: Vec<Target>,
    #[serde(default)]
    running_bundle_ids: HashSet<String>,
    #[serde(default = "default_true")]
    include_default_categories: bool,
}
#[derive(Clone)]
struct Task {
    root: PathBuf,
    category: &'static str,
    owner: Option<String>,
    logs: bool,
    target: Option<Target>,
}
#[derive(Clone, Debug, Serialize)]
pub struct Candidate {
    pub id: String,
    pub category: String,
    pub path: PathBuf,
    pub logical_bytes: u64,
    pub allocated_bytes: u64,
    pub autoselected: bool,
    pub owner: Option<String>,
    pub blocked_reason: Option<String>,
    pub device: u64,
    pub inode: u64,
    pub fingerprint: u64,
    pub cleanup_action: String,
    pub detail: Option<String>,
    pub dependency_running: bool,
}
#[derive(Serialize)]
struct ScanError {
    path: String,
    message: String,
}
struct State {
    cancel: AtomicBool,
    finished: AtomicBool,
    visited: AtomicU64,
    next_id: AtomicU64,
    workers: AtomicUsize,
    ready: Mutex<VecDeque<Candidate>>,
    candidates: Mutex<HashMap<String, Candidate>>,
    errors: Mutex<Vec<ScanError>>,
    tasks: Mutex<VecDeque<Task>>,
    request: Request,
    paths: Mutex<HashSet<PathBuf>>,
}
pub struct Session {
    state: Arc<State>,
    threads: Vec<JoinHandle<()>>,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.state.cancel.store(true, Ordering::Relaxed);
        for worker in self.threads.drain(..) {
            let _ = worker.join();
        }
    }
}

fn no_symlink_ancestors(path: &Path) -> Result<(), String> {
    for p in path.ancestors() {
        let m = fs::symlink_metadata(p)
            .map_err(|e| format!("No se pudo verificar {}: {e}", p.display()))?;
        if m.file_type().is_symlink() {
            return Err("La ruta contiene un enlace simbólico".into());
        }
    }
    Ok(())
}
fn protection(path: &Path, m: &Metadata) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use std::os::macos::fs::MetadataExt;
        if m.st_flags() & 0x4000_0000 != 0 {
            return Err("Archivo de la nube no descargado (SF_DATALESS)".into());
        }
        if m.st_flags()
            & (libc::UF_IMMUTABLE | libc::SF_IMMUTABLE | 0x0008_0000/* SF_RESTRICTED, sys/stat.h */)
            != 0
        {
            return Err("Archivo inmutable o restringido".into());
        }
        let p = CString::new(path.as_os_str().as_bytes()).map_err(|_| "Ruta no válida")?;
        let result = unsafe {
            libc::getxattr(
                p.as_ptr(),
                c"com.apple.rootless".as_ptr(),
                std::ptr::null_mut(),
                0,
                0,
                libc::XATTR_NOFOLLOW,
            )
        };
        if result >= 0 {
            return Err("Protegido por SIP (com.apple.rootless)".into());
        }
        let err = std::io::Error::last_os_error();
        if !matches!(err.raw_os_error(), Some(libc::ENOATTR | libc::ENOTSUP)) {
            return Err(format!("No se pudo comprobar SIP: {err}"));
        }
    }
    Ok(())
}
fn writable(path: &Path) -> bool {
    CString::new(path.as_os_str().as_bytes())
        .is_ok_and(|p| unsafe { libc::access(p.as_ptr(), libc::W_OK) } == 0)
}
fn entries(path: &Path) -> Result<Vec<PathBuf>, String> {
    let mut paths = fs::read_dir(path)
        .map_err(|e| e.to_string())?
        .map(|v| v.map(|e| e.path()).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    paths.sort();
    Ok(paths)
}
fn record_error(state: &State, path: &Path, message: String) {
    state.errors.lock().unwrap().push(ScanError {
        path: path.to_string_lossy().into_owned(),
        message,
    });
}
struct Snapshot {
    logical: u64,
    allocated: u64,
    fingerprint: u64,
    device: u64,
    inode: u64,
    blocked: Option<String>,
}
fn snapshot(
    path: &Path,
    state: &State,
    extra: Option<&Rules>,
    owner: Option<&str>,
    package: bool,
) -> Result<Snapshot, String> {
    no_symlink_ancestors(path)?;
    let first = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    let mut result = Snapshot {
        logical: 0,
        allocated: 0,
        fingerprint: 0,
        device: first.dev(),
        inode: first.ino(),
        blocked: None,
    };
    let mut pending = vec![path.to_path_buf()];
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut inodes = HashSet::new();
    while let Some(current) = pending.pop() {
        if state.cancel.load(Ordering::Relaxed) {
            return Err("Cancelado".into());
        }
        state.visited.fetch_add(1, Ordering::Relaxed);
        if state.request.rules.ignored(&current, owner)
            || extra.is_some_and(|r| r.ignored(&current, owner))
        {
            result
                .blocked
                .get_or_insert("Contiene una ruta excluida".into());
        }
        let m =
            fs::symlink_metadata(&current).map_err(|e| format!("{}: {e}", current.display()))?;
        current.hash(&mut hasher);
        (
            m.dev(),
            m.ino(),
            m.mode(),
            m.size(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        )
            .hash(&mut hasher);
        if m.file_type().is_symlink() {
            if !package {
                result
                    .blocked
                    .get_or_insert("Contiene enlaces simbólicos".into());
            } else if let Err(reason) = protection(&current, &m) {
                result.blocked.get_or_insert(reason);
            }
            continue;
        }
        if m.dev() != first.dev() {
            return Err("Contiene otro volumen montado".into());
        }
        if let Err(reason) = protection(&current, &m) {
            result.blocked.get_or_insert(reason);
        }
        if !package && !writable(&current) {
            result
                .blocked
                .get_or_insert("Contiene archivos sin permiso de escritura".into());
        }
        if m.is_dir() {
            pending.extend(entries(&current)?);
        } else if m.is_file() {
            // Hardlinks may also belong to data outside a cache; do not offer them for cleanup.
            if m.nlink() > 1 {
                result
                    .blocked
                    .get_or_insert("Contiene archivos con enlaces físicos compartidos".into());
            }
            result.logical = result.logical.saturating_add(m.len());
            if inodes.insert((m.dev(), m.ino())) {
                result.allocated = result
                    .allocated
                    .saturating_add(m.blocks().saturating_mul(512));
            }
        } else {
            result
                .blocked
                .get_or_insert("Contiene un archivo especial".into());
        }
    }
    result.fingerprint = hasher.finish();
    Ok(result)
}
fn add_candidate(state: &State, path: &Path, task: &Task) {
    if path.to_str().is_none() {
        record_error(
            state,
            path,
            "Ruta no representable como UTF-8; omitida".into(),
        );
        return;
    }
    if path.file_name().is_some_and(|s| s == ".DS_Store") {
        return;
    }
    let relative_cache_name = path
        .strip_prefix(state.request.home.join("Library/Caches"))
        .ok()
        .and_then(|p| p.to_str());
    let owner = task
        .owner
        .clone()
        .or_else(|| {
            relative_cache_name.and_then(|name| state.request.cache_owners.get(name).cloned())
        })
        .or_else(|| {
            path.file_name()
                .and_then(|n| n.to_str())
                .and_then(|name| state.request.cache_owners.get(name).cloned())
        })
        .or_else(|| {
            path.file_name()
                .and_then(|n| n.to_str())
                .filter(|n| state.request.installed_bundle_ids.contains(*n))
                .map(str::to_owned)
        });
    if state.request.rules.ignored(path, owner.as_deref()) {
        return;
    }
    let m = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) => {
            record_error(state, path, e.to_string());
            return;
        }
    };
    if m.file_type().is_symlink() {
        record_error(state, path, "Enlace simbólico omitido".into());
        return;
    }
    if task.logs && (!m.is_file() || m.len() <= 10_240 || !writable(path)) {
        return;
    }
    if state.paths.lock().unwrap().contains(path) {
        return;
    }
    let package = task
        .target
        .as_ref()
        .is_some_and(|t| t.category == "applications");
    match snapshot(path, state, None, owner.as_deref(), package) {
        Ok(mut s) if s.logical > 0 => {
            if !path.parent().is_some_and(writable) {
                s.blocked
                    .get_or_insert("Sin permiso para modificar el directorio padre".into());
            }
            let dependency_running = owner
                .as_ref()
                .is_some_and(|o| state.request.running_bundle_ids.contains(o));
            let autoselected = s.blocked.is_none()
                && task.category != "gradle"
                && !(task.category == "derivedData"
                    && path
                        .file_name()
                        .is_some_and(|n| n == "ModuleCache.noindex" || n == "SymbolCache.noindex"));
            let item = Candidate {
                id: state.next_id.fetch_add(1, Ordering::Relaxed).to_string(),
                category: task
                    .target
                    .as_ref()
                    .map(|t| t.category.clone())
                    .unwrap_or_else(|| task.category.into()),
                path: path.into(),
                logical_bytes: s.logical,
                allocated_bytes: s.allocated,
                autoselected: !dependency_running
                    && s.blocked.is_none()
                    && task
                        .target
                        .as_ref()
                        .map(|t| {
                            t.autoselected
                                && ![
                                    "trash",
                                    "simulators",
                                    "simulatorRuntimes",
                                    "documentVersions",
                                    "leftovers",
                                    "applications",
                                    "quarantineLogs",
                                    "diagnosticLogs",
                                    "mailTrash",
                                ]
                                .contains(&t.category.as_str())
                        })
                        .unwrap_or(autoselected),
                owner,
                blocked_reason: s.blocked,
                device: s.device,
                inode: s.inode,
                fingerprint: s.fingerprint,
                cleanup_action: match task.target.as_ref().map(|t| t.category.as_str()) {
                    Some("trash") => "emptyTrash",
                    Some("simulators") => "simulator",
                    Some("simulatorRuntimes") => "runtime",
                    Some("documentVersions") => "version",
                    Some("brokenAgents") => "agent",
                    Some("quarantineLogs") => "quarantine",
                    _ => "trash",
                }
                .into(),
                detail: task.target.as_ref().and_then(|t| t.detail.clone()),
                dependency_running,
            };
            if !state.paths.lock().unwrap().insert(item.path.clone()) {
                return;
            }
            let mut known = state.candidates.lock().unwrap();
            known.insert(item.id.clone(), item.clone());
            drop(known);
            state.ready.lock().unwrap().push_back(item);
        }
        Ok(_) => {}
        Err(e) => {
            if !state.cancel.load(Ordering::Relaxed) {
                record_error(state, path, e);
            }
        }
    }
}
fn scan_task(state: &State, task: &Task) {
    if !task.root.exists() {
        if let Err(e) = fs::symlink_metadata(&task.root) {
            if e.kind() != std::io::ErrorKind::NotFound {
                record_error(state, &task.root, e.to_string());
            }
        }
        return;
    }
    if let Err(e) = no_symlink_ancestors(&task.root) {
        record_error(state, &task.root, e);
        return;
    }
    if let Some(target) = &task.target {
        if targets::allowed(&state.request.home, target) {
            add_candidate(state, &target.path, task);
        } else {
            record_error(
                state,
                &target.path,
                "Objetivo fuera de la categoría admitida".into(),
            );
        }
        return;
    }
    let mut dirs = vec![(task.root.clone(), task.owner.clone())];
    while let Some((dir, owner)) = dirs.pop() {
        if state.cancel.load(Ordering::Relaxed) {
            return;
        }
        if state.request.rules.ignored(&dir, owner.as_deref()) {
            continue;
        }
        match entries(&dir) {
            Ok(paths) => {
                for path in paths {
                    if state.cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    if task.logs {
                        match fs::symlink_metadata(&path) {
                            Ok(m) if m.is_dir() => {
                                if no_symlink_ancestors(&path).is_ok() {
                                    let child_owner = owner.clone().or_else(|| {
                                        path.file_name()
                                            .and_then(|n| n.to_str())
                                            .filter(|n| {
                                                state.request.installed_bundle_ids.contains(*n)
                                            })
                                            .map(str::to_owned)
                                    });
                                    dirs.push((path, child_owner));
                                } else {
                                    record_error(
                                        state,
                                        &path,
                                        "Directorio protegido omitido".into(),
                                    );
                                }
                            }
                            _ => add_candidate(
                                state,
                                &path,
                                &Task {
                                    owner: owner.clone(),
                                    ..task.clone()
                                },
                            ),
                        }
                    } else if task.category == "userCaches"
                        && path.file_name().is_some_and(|n| n == "Google")
                        && fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir())
                    {
                        // A shared vendor cache must not hide the dependency of an individual browser.
                        match entries(&path) {
                            Ok(children) => {
                                for child in children {
                                    add_candidate(state, &child, task);
                                }
                            }
                            Err(e) => record_error(state, &path, e),
                        }
                    } else {
                        add_candidate(state, &path, task);
                    }
                }
            }
            Err(e) => record_error(state, &dir, e),
        }
    }
}
fn discover(state: &State) -> VecDeque<Task> {
    let home = &state.request.home;
    let mut tasks = if state.request.include_default_categories {
        VecDeque::from([
            Task {
                root: home.join("Library/Caches"),
                category: "userCaches",
                owner: None,
                logs: false,
                target: None,
            },
            Task {
                root: home.join("Library/Logs"),
                category: "userLogs",
                owner: None,
                logs: true,
                target: None,
            },
            Task {
                root: home.join(".gradle/caches"),
                category: "gradle",
                owner: None,
                logs: false,
                target: None,
            },
            Task {
                root: home.join("Library/Developer/Xcode/DerivedData"),
                category: "derivedData",
                owner: Some("com.apple.dt.Xcode".into()),
                logs: false,
                target: None,
            },
        ])
    } else {
        VecDeque::new()
    };
    let containers = home.join("Library/Containers");
    if state.request.include_default_categories && containers.exists() {
        if let Err(e) = no_symlink_ancestors(&containers) {
            record_error(state, &containers, e);
            return tasks;
        }
        match entries(&containers) {
            Ok(paths) => {
                for path in paths {
                    if state.cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    if state.request.rules.ignored(&path, None) {
                        continue;
                    }
                    if !fs::symlink_metadata(&path).is_ok_and(|m| m.is_dir()) {
                        continue;
                    }
                    let key = path
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or_default();
                    let owner = state
                        .request
                        .container_owners
                        .get(key)
                        .cloned()
                        .or_else(|| {
                            state
                                .request
                                .installed_bundle_ids
                                .contains(key)
                                .then(|| key.to_owned())
                        });
                    for (suffix, category, logs) in [
                        ("Caches", "containerCaches", false),
                        ("Logs", "containerLogs", true),
                    ] {
                        tasks.push_back(Task {
                            root: path.join("Data/Library").join(suffix),
                            category,
                            owner: owner.clone(),
                            logs,
                            target: None,
                        });
                    }
                }
            }
            Err(e) => record_error(state, &containers, e),
        }
    }
    for target in &state.request.targets {
        if targets::allowed(home, target) {
            tasks.push_back(Task {
                root: target.path.clone(),
                category: "supplemental",
                owner: target.owner.clone(),
                logs: false,
                target: Some(target.clone()),
            });
        } else {
            record_error(
                state,
                &target.path,
                "Objetivo fuera de la categoría admitida".into(),
            );
        }
    }
    tasks
}
fn create(mut request: Request) -> Result<Session, String> {
    if request.version != VERSION || !request.rules.valid() || !request.home.is_absolute() {
        return Err("Solicitud o reglas incompatibles".into());
    }
    request.rules.normalize_paths();
    let original_home = request.home.clone();
    request.home = fs::canonicalize(&request.home).map_err(|e| e.to_string())?;
    if !request.home.is_dir() || request.home.parent().is_none() || request.home.to_str().is_none()
    {
        return Err("HOME no válido".into());
    }
    for target in &mut request.targets {
        if let Ok(relative) = target.path.strip_prefix("/var") {
            target.path = Path::new("/private/var").join(relative);
        }
        if let Ok(relative) = target.path.strip_prefix(&original_home) {
            target.path = request.home.join(relative);
        }
    }
    let state = Arc::new(State {
        cancel: AtomicBool::new(false),
        finished: AtomicBool::new(false),
        visited: AtomicU64::new(0),
        next_id: AtomicU64::new(1),
        workers: AtomicUsize::new(4),
        ready: Mutex::new(VecDeque::new()),
        candidates: Mutex::new(HashMap::new()),
        errors: Mutex::new(Vec::new()),
        tasks: Mutex::new(VecDeque::new()),
        request,
        paths: Mutex::new(HashSet::new()),
    });
    // Discover on a worker, so a large Containers directory never blocks the UI.
    let coordinator_state = state.clone();
    let coordinator = thread::Builder::new()
        .name("cleaner-scan".into())
        .spawn(move || {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                *coordinator_state.tasks.lock().unwrap() = discover(&coordinator_state);
                thread::scope(|scope| {
                    for _ in 0..4 {
                        let state = &coordinator_state;
                        scope.spawn(move || {
                            loop {
                                if state.cancel.load(Ordering::Relaxed) {
                                    break;
                                }
                                let task = state.tasks.lock().unwrap().pop_front();
                                match task {
                                    Some(t) => scan_task(state, &t),
                                    None => break,
                                }
                            }
                            state.workers.fetch_sub(1, Ordering::Relaxed);
                        });
                    }
                });
            }));
            if outcome.is_err() {
                // Do not unwind across the ABI; poisoned locks are recovered on polling.
                coordinator_state
                    .errors
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(ScanError {
                        path: coordinator_state
                            .request
                            .home
                            .to_string_lossy()
                            .into_owned(),
                        message: "Fallo interno del motor".into(),
                    });
            }
            coordinator_state.finished.store(true, Ordering::Release);
        })
        .map_err(|e| e.to_string())?;
    Ok(Session {
        state,
        threads: vec![coordinator],
    })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ValidateRequest {
    version: u32,
    id: String,
    rules: Rules,
    running_bundle_ids: HashSet<String>,
}
#[derive(Serialize)]
struct Validation {
    version: u32,
    valid: bool,
    reason: Option<String>,
    path: Option<PathBuf>,
}
fn validate(session: &Session, mut r: ValidateRequest) -> Validation {
    r.rules.normalize_paths();
    let check = || -> Result<PathBuf, String> {
        if r.version != VERSION || !r.rules.valid() {
            return Err("Reglas incompatibles".into());
        }
        let state = &session.state;
        if state.cancel.load(Ordering::Relaxed) {
            return Err("Sesión cancelada; vuelve a escanear".into());
        }
        let item = state
            .candidates
            .lock()
            .map_err(|_| "Sesión no disponible")?
            .get(&r.id)
            .cloned()
            .ok_or("Candidato desconocido")?;
        if let Some(reason) = item.blocked_reason {
            return Err(reason);
        }
        if item
            .owner
            .as_ref()
            .is_some_and(|o| r.running_bundle_ids.contains(o))
        {
            return Err("La app propietaria está en ejecución".into());
        }
        let supplemental = state.request.targets.iter().any(|t| {
            t.path == item.path
                && t.category == item.category
                && targets::allowed(&state.request.home, t)
        });
        if (!item.path.starts_with(&state.request.home) || item.path == state.request.home)
            && !supplemental
        {
            return Err("Ruta fuera de las raíces permitidas".into());
        }
        // IDs resolve only to candidates discovered inside fixed category roots; callers cannot supply a path.
        if !writable(item.path.parent().ok_or("Ruta sin padre")?) {
            return Err("Sin permiso para modificar el directorio padre".into());
        }
        // Darwin's writable cache root may carry com.apple.rootless while its children are exempt.
        // Check the target and its descendants, not the parent's SIP marker; OS permissions still apply.
        let s = snapshot(
            &item.path,
            state,
            Some(&r.rules),
            item.owner.as_deref(),
            item.category == "applications",
        )?;
        if let Some(reason) = s.blocked {
            return Err(reason);
        }
        if s.device != item.device || s.inode != item.inode || s.fingerprint != item.fingerprint {
            return Err("El objetivo cambió desde el escaneo; vuelve a escanear".into());
        }
        Ok(item.path)
    };
    match check() {
        Ok(path) => Validation {
            version: VERSION,
            valid: true,
            reason: None,
            path: Some(path),
        },
        Err(reason) => Validation {
            version: VERSION,
            valid: false,
            reason: Some(reason),
            path: None,
        },
    }
}

#[repr(C)]
pub struct Buffer {
    data: *mut u8,
    len: usize,
}
fn buffer(value: &impl Serialize) -> Buffer {
    match serde_json::to_vec(value) {
        Ok(v) => {
            let mut bytes = v.into_boxed_slice();
            let result = Buffer {
                data: bytes.as_mut_ptr(),
                len: bytes.len(),
            };
            std::mem::forget(bytes);
            result
        }
        Err(_) => Buffer {
            data: std::ptr::null_mut(),
            len: 0,
        },
    }
}
fn guarded_buffer(f: impl FnOnce() -> Buffer) -> Buffer {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(Buffer {
        data: std::ptr::null_mut(),
        len: 0,
    })
}
unsafe fn decode<T: serde::de::DeserializeOwned>(ptr: *const u8, len: usize) -> Option<T> {
    if ptr.is_null() || len == 0 || len > MAX_REQUEST {
        return None;
    }
    serde_json::from_slice(unsafe { std::slice::from_raw_parts(ptr, len) }).ok()
}
// Safety: callers provide live session pointers and valid borrowed buffers as declared in CleanerBridge.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cm_session_new(ptr: *const u8, len: usize) -> *mut Session {
    std::panic::catch_unwind(|| {
        unsafe { decode::<Request>(ptr, len) }
            .and_then(|r| create(r).ok())
            .map(|s| Box::into_raw(Box::new(s)))
            .unwrap_or(std::ptr::null_mut())
    })
    .unwrap_or(std::ptr::null_mut())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cm_session_poll(ptr: *mut Session) -> Buffer {
    guarded_buffer(|| {
        let Some(session) = (unsafe { ptr.as_ref() }) else {
            return Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            };
        };
        let state = &session.state;
        let mut queue = state.ready.lock().unwrap_or_else(|e| e.into_inner());
        let count = queue.len().min(128);
        let items: Vec<_> = queue.drain(..count).collect();
        let done = state.finished.load(Ordering::Acquire) && queue.is_empty();
        let errors = std::mem::take(&mut *state.errors.lock().unwrap_or_else(|e| e.into_inner()));
        buffer(
            &serde_json::json!({ "version": VERSION, "items": items, "errors": errors, "done": done, "cancelled": state.cancel.load(Ordering::Relaxed), "visited": state.visited.load(Ordering::Relaxed) }),
        )
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cm_session_validate(
    ptr: *mut Session,
    request: *const u8,
    len: usize,
) -> Buffer {
    guarded_buffer(|| {
        match (unsafe { ptr.as_ref() }, unsafe {
            decode::<ValidateRequest>(request, len)
        }) {
            (Some(s), Some(r)) => buffer(&validate(s, r)),
            _ => buffer(&Validation {
                version: VERSION,
                valid: false,
                reason: Some("Solicitud no válida".into()),
                path: None,
            }),
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cm_session_cancel(ptr: *mut Session) {
    if let Some(s) = unsafe { ptr.as_ref() } {
        s.state.cancel.store(true, Ordering::Relaxed);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cm_session_free(ptr: *mut Session) {
    if !ptr.is_null() {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            drop(unsafe { Box::from_raw(ptr) })
        }));
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cm_buffer_free(b: Buffer) {
    if !b.data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(b.data, b.len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    static FIXTURE_ID: AtomicUsize = AtomicUsize::new(0);
    struct Fixture {
        home: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let home = std::env::temp_dir().join(format!(
                "cleaner-rust-{}-{}",
                std::process::id(),
                FIXTURE_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&home).unwrap();
            Self {
                home: fs::canonicalize(home).unwrap(),
            }
        }
        fn file(&self, relative: &str, size: usize) -> PathBuf {
            let p = self.home.join(relative);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, vec![1u8; size]).unwrap();
            p
        }
        fn request(&self) -> Request {
            Request {
                version: 1,
                home: self.home.clone(),
                rules: rules(),
                installed_bundle_ids: HashSet::from(["com.example.App".into()]),
                container_owners: BTreeMap::new(),
                cache_owners: BTreeMap::new(),
                targets: Vec::new(),
                running_bundle_ids: HashSet::new(),
                include_default_categories: true,
            }
        }
        fn scan(&self, r: Request) -> Session {
            let session = create(r).unwrap();
            for _ in 0..5000 {
                if session.state.finished.load(Ordering::Acquire) {
                    return session;
                }
                thread::sleep(std::time::Duration::from_millis(1));
            }
            panic!("Scan timed out")
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.home).unwrap();
        }
    }
    fn rules() -> Rules {
        Rules {
            version: 1,
            paths: vec![],
            names: vec![],
            bundle_ids: vec![],
        }
    }
    fn items(s: &Session) -> Vec<Candidate> {
        s.state
            .candidates
            .lock()
            .unwrap()
            .values()
            .cloned()
            .collect()
    }
    fn validation(s: &Session, id: &str, r: Rules, running: &[&str]) -> Validation {
        validate(
            s,
            ValidateRequest {
                version: 1,
                id: id.into(),
                rules: r,
                running_bundle_ids: running.iter().map(|s| (*s).into()).collect(),
            },
        )
    }
    #[test]
    fn application_scan_is_scoped_and_does_not_follow_package_links() {
        let f = Fixture::new();
        f.file("Library/Caches/unrelated/data", 40);
        let binary = f.file("Applications/Example.app/Contents/MacOS/Example", 20);
        let external = f.file("Documents/keep", 70);
        let link = binary.parent().unwrap().join("external");
        std::os::unix::fs::symlink(&external, &link).unwrap();
        let mut request = f.request();
        request.include_default_categories = false;
        request.targets.push(Target {
            path: f.home.join("Applications/Example.app"),
            category: "applications".into(),
            owner: Some("com.example.App".into()),
            autoselected: true,
            detail: None,
        });
        let session = f.scan(request);
        let candidates = items(&session);
        assert_eq!(candidates.len(), 1);
        let app = &candidates[0];
        assert!(!app.autoselected);
        assert_eq!(app.logical_bytes, 20);
        assert!(validation(&session, &app.id, rules(), &[]).valid);
        assert!(!validation(&session, &app.id, rules(), &["com.example.App"]).valid);
        fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&binary, &link).unwrap();
        assert!(!validation(&session, &app.id, rules(), &[]).valid);
        assert_eq!(fs::metadata(external).unwrap().len(), 70);
    }
    #[test]
    fn cache_categories_thresholds_and_selection() {
        let f = Fixture::new();
        f.file("Library/Caches/foo/file", 50);
        f.file("Library/Caches/.DS_Store", 32);
        f.file("Library/Caches/empty", 0);
        f.file(".gradle/caches/modules/data", 16);
        f.file(
            "Library/Developer/Xcode/DerivedData/ModuleCache.noindex/a",
            12,
        );
        f.file(
            "Library/Developer/Xcode/DerivedData/SymbolCache.noindex/a",
            12,
        );
        f.file("Library/Developer/Xcode/DerivedData/MyApp-abc/a", 12);
        f.file("Library/Logs/small.log", 5120);
        f.file("Library/Logs/boundary.log", 10240);
        f.file("Library/Logs/nested/large.log", 10241);
        f.file(
            "Library/Containers/com.example.App/Data/Library/Caches/a/file",
            20,
        );
        f.file(
            "Library/Containers/com.example.App/Data/Library/Logs/large.log",
            12000,
        );
        f.file(
            "Library/Containers/com.example.App/Data/Documents/personal",
            20,
        );
        let s = f.scan(f.request());
        let found = items(&s);
        assert_eq!(found.len(), 8, "{found:?}");
        for item in &found {
            assert!(!item.path.ends_with("personal"));
            assert!(item.blocked_reason.is_none(), "{item:?}");
            let expected = !(item.category == "gradle"
                || item.path.ends_with("ModuleCache.noindex")
                || item.path.ends_with("SymbolCache.noindex"));
            assert_eq!(item.autoselected, expected);
        }
        assert!(
            found
                .iter()
                .filter(|i| i.category.starts_with("container"))
                .all(|i| i.owner.as_deref() == Some("com.example.App"))
        );
    }
    #[test]
    fn exclusions_block_parent_and_symlinks_never_escape() {
        let f = Fixture::new();
        let keep = f.file("Library/Caches/foo/keep", 10);
        f.file("Library/Caches/foo/other", 20);
        f.file("Library/Caches/outside-target", 30);
        symlink(
            f.home.join("Library/Caches/outside-target"),
            f.home.join("Library/Caches/link"),
        )
        .unwrap();
        symlink("other", f.home.join("Library/Caches/foo/nested-link")).unwrap();
        let mut request = f.request();
        request.rules.paths.push(keep);
        let s = f.scan(request);
        let found = items(&s);
        assert_eq!(found.len(), 2);
        let parent = found.iter().find(|i| i.path.ends_with("foo")).unwrap();
        assert!(parent.blocked_reason.is_some());
        assert!(!parent.autoselected);
        assert!(!validation(&s, &parent.id, rules(), &[]).valid);
        assert!(found.iter().all(|i| !i.path.ends_with("link")));
    }
    #[test]
    fn changed_files_current_rules_running_apps_and_unknown_id_rejected() {
        let f = Fixture::new();
        let target = f.file("Library/Caches/com.example.App/data", 10);
        let s = f.scan(f.request());
        let item = items(&s).pop().unwrap();
        assert!(validation(&s, &item.id, rules(), &[]).valid);
        assert!(!validation(&s, "../../arbitrary", rules(), &[]).valid);
        assert!(!validation(&s, &item.id, rules(), &["com.example.App"]).valid);
        let mut excluded = rules();
        excluded.paths.push(target.clone());
        assert!(!validation(&s, &item.id, excluded, &[]).valid);
        let mut by_bundle = rules();
        by_bundle.bundle_ids.push("com.example.App".into());
        assert!(!validation(&s, &item.id, by_bundle, &[]).valid);
        fs::write(target, b"changed length").unwrap();
        assert!(!validation(&s, &item.id, rules(), &[]).valid);
    }
    #[test]
    fn symlink_substitution_of_ancestor_is_rejected() {
        let f = Fixture::new();
        f.file("Library/Caches/foo/a", 10);
        let s = f.scan(f.request());
        let item = items(&s).pop().unwrap();
        let root = f.home.join("Library/Caches");
        let moved = f.home.join("saved");
        fs::rename(&root, &moved).unwrap();
        symlink(&moved, &root).unwrap();
        assert!(!validation(&s, &item.id, rules(), &[]).valid);
    }
    #[test]
    fn exclusions_by_name_and_bundle_and_log_ownership() {
        let f = Fixture::new();
        f.file("Library/Caches/ignored/a", 10);
        f.file("Library/Caches/com.example.App/a", 10);
        f.file("Library/Logs/com.example.App/sub/a.log", 12000);
        let mut r = f.request();
        r.rules.names.push("ignored".into());
        r.rules.bundle_ids.push("com.example.App".into());
        assert!(items(&f.scan(r)).is_empty());
        let s = f.scan(f.request());
        let logs = items(&s)
            .into_iter()
            .find(|i| i.category == "userLogs")
            .unwrap();
        assert_eq!(logs.owner.as_deref(), Some("com.example.App"));
    }
    #[test]
    fn readonly_logs_and_unreadable_directories_report_partial_results() {
        let f = Fixture::new();
        let log = f.file("Library/Logs/readonly", 12000);
        fs::set_permissions(&log, fs::Permissions::from_mode(0o400)).unwrap();
        let unreadable = f
            .file("Library/Caches/unreadable/a", 20)
            .parent()
            .unwrap()
            .to_path_buf();
        fs::set_permissions(&unreadable, fs::Permissions::from_mode(0)).unwrap();
        f.file("Library/Caches/good/a", 20);
        let s = f.scan(f.request());
        fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(items(&s).len(), 1);
        assert!(!s.state.errors.lock().unwrap().is_empty());
    }
    #[test]
    fn hardlinks_are_blocked_and_inode_replacement_is_detected() {
        let f = Fixture::new();
        let first = f.file("Library/Caches/foo/a", 30);
        fs::hard_link(&first, f.home.join("outside")).unwrap();
        let target = f.file("Library/Caches/regular", 40);
        let s = f.scan(f.request());
        let found = items(&s);
        assert!(
            found
                .iter()
                .find(|i| i.path.ends_with("foo"))
                .unwrap()
                .blocked_reason
                .is_some()
        );
        let item = found.iter().find(|i| i.path == target).unwrap();
        fs::rename(&target, f.home.join("old")).unwrap();
        fs::write(&target, vec![0; 40]).unwrap();
        assert!(!validation(&s, &item.id, rules(), &[]).valid);
    }
    #[test]
    fn malformed_rules_and_invalid_home_fail_closed() {
        let f = Fixture::new();
        let mut r = f.request();
        r.version = 2;
        assert!(create(r).is_err());
        let mut r = f.request();
        r.rules.version = 2;
        assert!(create(r).is_err());
        let mut r = f.request();
        r.home = "/".into();
        assert!(create(r).is_err());
        let mut r = f.request();
        r.rules.paths.push("relative".into());
        assert!(create(r).is_err());
    }
    #[test]
    fn abi_batches_buffers_cancellation_and_null_inputs() {
        let f = Fixture::new();
        for i in 0..270 {
            f.file(&format!("Library/Caches/file{i}"), 1);
        }
        let mut session = f.scan(f.request());
        let mut count = 0;
        loop {
            let b = unsafe { cm_session_poll(&mut session) };
            assert!(!b.data.is_null());
            let value: serde_json::Value =
                serde_json::from_slice(unsafe { std::slice::from_raw_parts(b.data, b.len) })
                    .unwrap();
            assert!(value["items"].as_array().unwrap().len() <= 128);
            count += value["items"].as_array().unwrap().len();
            unsafe {
                cm_buffer_free(b);
            }
            if value["done"] == true {
                break;
            }
        }
        assert_eq!(count, 270);
        let item = items(&session).pop().unwrap();
        unsafe {
            cm_session_cancel(&mut session);
        }
        assert!(!validation(&session, &item.id, rules(), &[]).valid);
        assert!(unsafe { cm_session_new(std::ptr::null(), 0) }.is_null());
        assert!(unsafe { cm_session_new(b"bad".as_ptr(), 3) }.is_null());
        let b = unsafe { cm_session_validate(&mut session, std::ptr::null(), 0) };
        assert!(!b.data.is_null());
        unsafe {
            cm_buffer_free(b);
            cm_session_free(std::ptr::null_mut());
        }
    }
    #[test]
    fn cancellation_during_scan_stops_workers() {
        let f = Fixture::new();
        for i in 0..300 {
            f.file(&format!("Library/Caches/tree/{i}"), 1);
        }
        let s = create(f.request()).unwrap();
        s.state.cancel.store(true, Ordering::Relaxed);
        drop(s); // joins all workers; it must not hang on undrained batches.
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn immutable_entry_is_rejected_without_clearing_flags() {
        let f = Fixture::new();
        let target = f.file("Library/Caches/locked", 20);
        let name = CString::new(target.as_os_str().as_bytes()).unwrap();
        assert_eq!(
            unsafe { libc::chflags(name.as_ptr(), libc::UF_IMMUTABLE) },
            0
        );
        let result = protection(&target, &fs::symlink_metadata(&target).unwrap());
        assert_eq!(unsafe { libc::chflags(name.as_ptr(), 0) }, 0);
        assert!(result.is_err());
    }
    #[test]
    fn display_name_aliases_and_shared_vendor_caches_keep_owner_dependencies() {
        let f = Fixture::new();
        f.file("Library/Caches/Codex/data", 20);
        f.file("Library/Caches/Google/Chrome/data", 20);
        let mut r = f.request();
        r.cache_owners
            .insert("Codex".into(), "com.openai.codex".into());
        r.cache_owners
            .insert("Google/Chrome".into(), "com.google.Chrome".into());
        r.running_bundle_ids.insert("com.openai.codex".into());
        r.running_bundle_ids.insert("com.google.Chrome".into());
        let s = f.scan(r);
        let found = items(&s);
        assert_eq!(found.len(), 2);
        assert!(
            found
                .iter()
                .all(|i| i.owner.is_some() && i.dependency_running && !i.autoselected)
        );
        assert!(found.iter().any(|i| i.path.ends_with("Google/Chrome")));
    }

    #[test]
    fn running_owners_are_not_preselected_but_can_be_revalidated_after_closing() {
        let f = Fixture::new();
        f.file("Library/Caches/com.example.App/a", 20);
        let mut request = f.request();
        request.running_bundle_ids.insert("com.example.App".into());
        let s = f.scan(request);
        let found = items(&s);
        let item = &found[0];
        assert!(item.dependency_running);
        assert!(!item.autoselected);
        assert!(item.blocked_reason.is_none());
        assert!(validation(&s, &item.id, rules(), &[]).valid);
        assert!(!validation(&s, &item.id, rules(), &["com.example.App"]).valid);
    }

    #[test]
    fn supplemental_targets_enforce_category_scope_and_cleanup_actions() {
        let f = Fixture::new();
        let dmg = f.file("Downloads/review.dmg", 20);
        let trash = f.file(".Trash/disposable", 20);
        let private = f.file("Documents/keep", 20);
        let mut r = f.request();
        for (path, category) in [
            (dmg.clone(), "diskImages"),
            (trash.clone(), "trash"),
            (private.clone(), "trash"),
        ] {
            r.targets.push(Target {
                path,
                category: category.into(),
                owner: None,
                autoselected: false,
                detail: None,
            });
        }
        let s = f.scan(r);
        let found = items(&s);
        assert_eq!(found.len(), 2);
        assert!(found.iter().all(|i| i.path != private));
        assert_eq!(
            found
                .iter()
                .find(|i| i.path == trash)
                .unwrap()
                .cleanup_action,
            "emptyTrash"
        );
        assert!(found.iter().all(|i| !i.autoselected));
        for item in found {
            assert!(validation(&s, &item.id, rules(), &[]).valid);
        }
    }

    #[test]
    #[ignore = "reproducible metadata benchmark on generated fixtures"]
    fn benchmark_fixture_scan() {
        let f = Fixture::new();
        for root in [
            "Library/Caches",
            ".gradle/caches",
            "Library/Developer/Xcode/DerivedData",
            "Library/Containers/com.example.App/Data/Library/Caches",
        ] {
            for group in 0..16 {
                for file in 0..32 {
                    f.file(&format!("{root}/group{group}/file{file}"), 256);
                }
            }
        }
        let mut millis = Vec::new();
        for _ in 0..9 {
            let started = std::time::Instant::now();
            let s = f.scan(f.request());
            let found = items(&s);
            assert_eq!(found.len(), 64);
            assert_eq!(found.iter().map(|i| i.logical_bytes).sum::<u64>(), 524_288);
            millis.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        millis.sort_by(|a, b| a.total_cmp(b));
        println!(
            "metadata benchmark: 2048 files, 64 candidates, 4 workers, 9 runs, hot/mixed cache; median={:.2} ms min={:.2} ms max={:.2} ms",
            millis[4], millis[0], millis[8]
        );
    }

    #[test]
    fn non_utf8_errors_cannot_poison_abi_batches() {
        use std::os::unix::ffi::OsStringExt;
        let f = Fixture::new();
        f.file("Library/Caches/good", 1);
        let mut s = f.scan(f.request());
        let bad = f.home.join(std::ffi::OsString::from_vec(vec![0xff]));
        record_error(&s.state, &bad, "Non UTF8".into());
        let b = unsafe { cm_session_poll(&mut s) };
        assert!(!b.data.is_null());
        unsafe {
            cm_buffer_free(b);
        }
        assert_eq!(items(&s).len(), 1);
    }
}
