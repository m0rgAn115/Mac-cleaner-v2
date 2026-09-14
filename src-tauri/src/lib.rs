use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use tauri::{AppHandle, Manager, State};

#[derive(Default)]
struct ReportState(Mutex<Option<Value>>);

fn scanner_script(app: &AppHandle) -> Result<PathBuf, String> {
    if let Some(explicit) = std::env::var_os("MAC_CLEANER_SCRIPT") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Ok(path);
        }
    }

    let bundled = app
        .path()
        .resource_dir()
        .map(|path| path.join("python/mac-cleaner"))
        .ok()
        .filter(|path| path.is_file());

    if !cfg!(debug_assertions) {
        if let Some(path) = bundled.clone() {
            return Ok(path);
        }
    }

    let development = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(|path| path.join("mac-cleaner"));
    if let Some(path) = development {
        if path.is_file() {
            return Ok(path);
        }
    }

    bundled.ok_or_else(|| "The bundled Python scanner was not found in Resources".to_string())
}

fn python_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(explicit) = std::env::var_os("MAC_CLEANER_PYTHON") {
        candidates.push(PathBuf::from(explicit));
    }
    candidates.push(PathBuf::from("python3"));
    if let Some(home) = std::env::var_os("HOME") {
        candidates.push(PathBuf::from(home).join(".pyenv/shims/python3"));
    }
    candidates.push(PathBuf::from("/opt/homebrew/bin/python3"));
    candidates.push(PathBuf::from("/usr/local/bin/python3"));
    candidates.push(PathBuf::from("/usr/bin/python3"));
    candidates
}

fn run_python_scan(script: &Path, developer: bool, large: bool) -> Result<Value, String> {
    let mut last_error = String::from("Python 3.10 or later was not found.");
    for python in python_candidates() {
        let version = Command::new(&python).arg("--version").output();
        if version.is_err() {
            continue;
        }
        let mut command = Command::new(&python);
        command.env("PYTHONDONTWRITEBYTECODE", "1");
        command.arg(script).arg("scan").arg("--json");
        if developer {
            command.arg("--developer");
        }
        if large {
            command.arg("--large");
        }
        match command.output() {
            Ok(output) if output.status.success() => {
                return serde_json::from_slice(&output.stdout)
                    .map_err(|error| format!("The scanner returned invalid JSON: {error}"));
            }
            Ok(output) => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                last_error = format!("The scanner failed with {}: {}", output.status, stderr.trim());
            }
            Err(error) => last_error = format!("Could not run {}: {error}", python.display()),
        }
    }
    Err(last_error)
}

fn run_python_cleanup(
    script: &Path,
    classification: &str,
    mode: &str,
    items: Vec<Value>,
) -> Result<Value, String> {
    let manifest = serde_json::to_vec(&json!({"items": items}))
        .map_err(|error| format!("Could not prepare the manifest: {error}"))?;
    let mut last_error = String::from("Python 3.10 or later was not found.");
    for python in python_candidates() {
        if Command::new(&python).arg("--version").output().is_err() {
            continue;
        }
        let mut child = match Command::new(&python)
            .env("PYTHONDONTWRITEBYTECODE", "1")
            .arg(script)
            .arg("_apply-manifest")
            .arg("--mode")
            .arg(mode)
            .arg("--classification")
            .arg(classification)
            .arg("--yes")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(error) => {
                last_error = format!("Could not run {}: {error}", python.display());
                continue;
            }
        };
        if let Some(mut stdin) = child.stdin.take() {
            if let Err(error) = stdin.write_all(&manifest) {
                let _ = child.kill();
                last_error = format!("Could not send the plan to the executor: {error}");
                continue;
            }
        }
        match child.wait_with_output() {
            Ok(output) if output.status.success() => {
                return serde_json::from_slice(&output.stdout)
                    .map_err(|error| format!("The executor returned invalid JSON: {error}"));
            }
            Ok(output) => {
                last_error = format!(
                    "The executor refused to continue ({}): {}",
                    output.status,
                    String::from_utf8_lossy(&output.stderr).trim()
                );
            }
            Err(error) => last_error = format!("The cleanup process failed: {error}"),
        }
    }
    Err(last_error)
}

fn actionable(item: &Value) -> bool {
    item.get("metadata")
        .and_then(|metadata| metadata.get("actionable"))
        .and_then(Value::as_bool)
        != Some(false)
}

fn report_summary(report: &Value) -> Value {
    let mut categories: BTreeMap<(String, String), (u64, u64, u64, u64)> = BTreeMap::new();
    let mut actionable_totals: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    if let Some(items) = report.get("items").and_then(Value::as_array) {
        for item in items {
            let classification = item
                .get("classification")
                .and_then(Value::as_str)
                .unwrap_or("REVIEW");
            let category = item
                .get("category")
                .and_then(Value::as_str)
                .unwrap_or("Other");
            let size = item.get("size").and_then(Value::as_u64).unwrap_or(0);
            let entry = categories
                .entry((classification.to_string(), category.to_string()))
                .or_insert((0, 0, 0, 0));
            entry.0 = entry.0.saturating_add(size);
            entry.1 += 1;
            if actionable(item) && classification != "PROTECTED" {
                entry.2 = entry.2.saturating_add(size);
                entry.3 += 1;
                let total = actionable_totals
                    .entry(classification.to_string())
                    .or_insert((0, 0));
                total.0 = total.0.saturating_add(size);
                total.1 += 1;
            }
        }
    }
    let category_values: Vec<Value> = categories
        .into_iter()
        .map(
            |((classification, category), (size, count, actionable_size, actionable_count))| {
                json!({
                    "classification": classification,
                    "category": category,
                    "size": size,
                    "count": count,
                    "actionable_size": actionable_size,
                    "actionable_count": actionable_count
                })
            },
        )
        .collect();

    json!({
        "generated_at": report.get("generated_at").cloned().unwrap_or(Value::Null),
        "platform": report.get("platform").cloned().unwrap_or_else(|| json!({})),
        "storage": report.get("storage").cloned().unwrap_or_else(|| json!({})),
        "home_size": report.get("home_size").cloned().unwrap_or(Value::Null),
        "totals": report.get("totals").cloned().unwrap_or_else(|| json!({})),
        "actionable_totals": actionable_totals.into_iter().map(|(kind, (size, count))| {
            (kind, json!({"size": size, "count": count}))
        }).collect::<serde_json::Map<String, Value>>(),
        "home_breakdown": report.get("home_breakdown").cloned().unwrap_or_else(|| json!([])),
        "notices": report.get("notices").cloned().unwrap_or_else(|| json!([])),
        "errors": report.get("errors").cloned().unwrap_or_else(|| json!([])),
        "categories": category_values
    })
}

fn compact_cleanup_record(record: Value) -> Value {
    let results = record.get("results").and_then(Value::as_array);
    let succeeded = results.map_or(0, |rows| {
        rows.iter()
            .filter(|row| row.get("success").and_then(Value::as_bool) == Some(true))
            .count()
    });
    let failed_rows: Vec<Value> = results
        .into_iter()
        .flatten()
        .filter(|row| row.get("success").and_then(Value::as_bool) != Some(true))
        .take(50)
        .cloned()
        .collect();
    let failed = results.map_or(0, |rows| rows.len().saturating_sub(succeeded));
    json!({
        "timestamp": record.get("timestamp").cloned().unwrap_or(Value::Null),
        "classification": record.get("classification").cloned().unwrap_or(Value::Null),
        "mode": record.get("mode").cloned().unwrap_or(Value::Null),
        "before_available": record.get("before_available").cloned().unwrap_or(Value::Null),
        "after_available": record.get("after_available").cloned().unwrap_or(Value::Null),
        "reclaimed": record.get("reclaimed").cloned().unwrap_or(Value::Null),
        "estimated_processed": record.get("estimated_processed").cloned().unwrap_or(Value::Null),
        "audit_path": record.get("audit_path").cloned().unwrap_or(Value::Null),
        "succeeded": succeeded,
        "failed": failed,
        "failure_details": failed_rows,
    })
}

#[tauri::command]
async fn scan_storage(
    app: AppHandle,
    state: State<'_, ReportState>,
    developer: bool,
    large: bool,
) -> Result<Value, String> {
    let script = scanner_script(&app)?;
    let report =
        tauri::async_runtime::spawn_blocking(move || run_python_scan(&script, developer, large))
            .await
            .map_err(|error| format!("The scan task was interrupted: {error}"))??;
    let summary = report_summary(&report);
    *state
        .0
        .lock()
        .map_err(|_| "Could not lock the report".to_string())? = Some(report);
    Ok(summary)
}

#[tauri::command]
fn list_items(
    state: State<'_, ReportState>,
    classification: String,
    category: Option<String>,
    query: Option<String>,
    offset: usize,
    limit: usize,
) -> Result<Value, String> {
    let guard = state
        .0
        .lock()
        .map_err(|_| "Could not read the report".to_string())?;
    let report = guard
        .as_ref()
        .ok_or_else(|| "Run a scan first".to_string())?;
    let needle = query.unwrap_or_default().to_lowercase();
    let mut matches: Vec<&Value> = report
        .get("items")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|item| {
            item.get("classification").and_then(Value::as_str) == Some(classification.as_str())
        })
        .filter(|item| {
            category.as_deref().map_or(true, |wanted| {
                let actual = item.get("category").and_then(Value::as_str).unwrap_or("");
                if wanted == "__developer__" {
                    [
                        "developer",
                        "docker",
                        "xcode",
                        "gradle",
                        "npm",
                        "python",
                        "homebrew",
                    ]
                    .iter()
                    .any(|term| actual.to_lowercase().contains(term))
                } else {
                    actual == wanted
                }
            })
        })
        .filter(|item| {
            needle.is_empty()
                || ["path", "reason", "category"]
                    .iter()
                    .filter_map(|key| item.get(key).and_then(Value::as_str))
                    .any(|value| value.to_lowercase().contains(&needle))
        })
        .collect();
    matches.sort_by_key(|item| {
        std::cmp::Reverse(item.get("size").and_then(Value::as_u64).unwrap_or(0))
    });
    let total = matches.len();
    let page: Vec<Value> = matches
        .into_iter()
        .skip(offset)
        .take(limit.clamp(1, 200))
        .cloned()
        .collect();
    Ok(json!({"items": page, "total": total, "offset": offset, "limit": limit.clamp(1, 200)}))
}

#[tauri::command]
fn reveal_path(path: String) -> Result<(), String> {
    if path.contains("://") {
        return Err("This item does not represent a local path".to_string());
    }
    let requested = PathBuf::from(path);
    let canonical = requested
        .canonicalize()
        .map_err(|error| format!("Could not resolve the path: {error}"))?;
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "Could not determine HOME".to_string())?
        .canonicalize()
        .map_err(|error| format!("Could not resolve HOME: {error}"))?;
    if canonical == home || !canonical.starts_with(&home) {
        return Err("Only items inside your home folder can be revealed".to_string());
    }
    let status = Command::new("/usr/bin/open")
        .arg("-R")
        .arg("--")
        .arg(&canonical)
        .status()
        .map_err(|error| format!("Could not open Finder: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("Finder returned {status}"))
    }
}

#[tauri::command]
async fn execute_cleanup(
    app: AppHandle,
    state: State<'_, ReportState>,
    classification: String,
    paths: Vec<String>,
    mode: String,
    all_safe: bool,
) -> Result<Value, String> {
    if classification != "SAFE" && classification != "REVIEW" {
        return Err("Only SAFE or REVIEW actions are allowed".to_string());
    }
    if mode != "trash" && mode != "delete" {
        return Err("Unrecognized action".to_string());
    }
    if classification == "SAFE" && (!all_safe || mode != "delete" || !paths.is_empty()) {
        return Err(
            "SAFE only supports cleaning the entire confirmed plan through direct deletion".to_string(),
        );
    }
    if classification == "REVIEW" && (all_safe || paths.is_empty() || paths.len() > 500) {
        return Err("Select between 1 and 500 REVIEW items".to_string());
    }

    let selected = {
        let guard = state
            .0
            .lock()
            .map_err(|_| "Could not read the report".to_string())?;
        let report = guard
            .as_ref()
            .ok_or_else(|| "The report is no longer valid; scan again".to_string())?;
        let items = report
            .get("items")
            .and_then(Value::as_array)
            .ok_or_else(|| "The report contains no items".to_string())?;
        if classification == "SAFE" {
            items
                .iter()
                .filter(|item| item.get("classification").and_then(Value::as_str) == Some("SAFE"))
                .filter(|item| actionable(item))
                .cloned()
                .collect::<Vec<Value>>()
        } else {
            let requested: std::collections::BTreeSet<&str> =
                paths.iter().map(String::as_str).collect();
            if requested.len() != paths.len() {
                return Err("The selection contains duplicate paths".to_string());
            }
            let chosen: Vec<Value> = items
                .iter()
                .filter(|item| item.get("classification").and_then(Value::as_str) == Some("REVIEW"))
                .filter(|item| {
                    item.get("path")
                        .and_then(Value::as_str)
                        .is_some_and(|path| requested.contains(path))
                })
                .filter(|item| actionable(item))
                .cloned()
                .collect();
            if chosen.len() != requested.len() {
                return Err(
                    "The selection includes missing, protected, or non-actionable items"
                        .to_string(),
                );
            }
            chosen
        }
    };
    if selected.is_empty() {
        return Err("This plan contains no actionable items".to_string());
    }
    let script = scanner_script(&app)?;
    let task_classification = classification.clone();
    let task_mode = mode.clone();
    let record = tauri::async_runtime::spawn_blocking(move || {
        run_python_cleanup(&script, &task_classification, &task_mode, selected)
    })
    .await
    .map_err(|error| format!("The cleanup task was interrupted: {error}"))??;
    *state
        .0
        .lock()
        .map_err(|_| "Could not invalidate the report".to_string())? = None;
    Ok(compact_cleanup_record(record))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(ReportState::default())
        .invoke_handler(tauri::generate_handler![
            scan_storage,
            list_items,
            reveal_path,
            execute_cleanup
        ])
        .run(tauri::generate_context!())
        .expect("error while running Mac Cleaner Local");
}
