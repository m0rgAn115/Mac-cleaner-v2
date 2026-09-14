# Architecture and safety boundaries

```text
macOS/filesystem/native tools
        │ read-only scan
        ▼
bounded scanners ──► immutable ScanItem report ──► Rust-held sealed report
        │                       │                           │
        └── ignore policy       │ exact identity           ├── paginated UI
                                │ path/category/reason      └── exact selection
                                ▼
                   confirmation + executor allowlists
                                │
                 re-stat / owner / symlink / containment
                                │
                      action + JSON audit + df delta
```

## Trust boundaries

The WebView sends classifications and selected path strings, never arbitrary
commands or complete trusted records. Rust resolves those strings against the
in-memory report and passes only exact matching observations to Python. SAFE is
an all-plan operation; REVIEW is capped at 500 unique selected paths. Any action
invalidates the report.

`executor.py` does not trust scan metadata by itself. SAFE direct roots must also
match its independent allowlist. REVIEW paths must fit a recognized policy and
remain inside the user's home. The centralized gate rejects protected locations,
root/home, symlinks anywhere in the path, changed device/inode/size/mtime, paths
outside the allowed root, and non-user-owned targets.

Directories selected under REVIEW may only be renamed atomically into `~/.Trash`.
There is no recursive direct deletion and no cross-filesystem fallback. Permanent
REVIEW deletion accepts regular files only. Trash and audit destinations are
checked for symlink/ownership attacks before use.

Homebrew and unavailable Simulator cleanup are delegated to their supported tools
after a fresh preview/query. Docker, volumes, Time Machine snapshots, simulator
runtimes, Trash aggregates, and unclear package-manager results remain advisory.

## Modules

- `models.py`: classifications, identity snapshots, item type, and reports.
- `config.py`: thresholds and persistent ignore rules.
- `fs.py`: no-follow traversal and size accounting.
- `scanners.py`: bounded scanners and read-only native-tool queries.
- `safety.py`: centralized protected-root and TOCTOU validation.
- `executor.py`: narrow actions, Trash moves, manager delegation, and audits.
- `reporting.py`: terminal summaries, exact details, and JSON.
- `cli.py`: read-only defaults, interactive SAFE cleanup, history, and the private
  manifest boundary used by Tauri.
- `src-tauri/src/lib.rs`: sealed report state, exact selection matching, and native
  command bridge.
