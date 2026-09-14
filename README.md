<p align="center">
  <img src="./src-tauri/icons/icon.png" width="112" alt="Mac Cleaner Local" />
</p>

<h1 align="center">Mac Cleaner Local</h1>

<p align="center">
  Scan, understand, and reclaim space on macOS without turning cleanup<br />
  into a gamble with your important files.
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-12%2B-111827?style=flat-square&logo=apple&logoColor=white" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-111827?style=flat-square" />
  <img alt="Python" src="https://img.shields.io/badge/Python-3.10%2B-3776AB?style=flat-square&logo=python&logoColor=white" />
  <img alt="Tauri" src="https://img.shields.io/badge/Tauri-2-24C8DB?style=flat-square&logo=tauri&logoColor=white" />
  <img alt="Privacy" src="https://img.shields.io/badge/data-100%25%20local-20B783?style=flat-square" />
</p>

---

![Mac Cleaner Local storage overview](./docs/screenshots/overview.png)

## What is it?

**Mac Cleaner Local** is a macOS desktop app inspired by CleanMyMac's storage
cleanup features. Its purpose is not to display the largest possible amount of
“junk,” but to answer clearly:

- Where is storage being used?
- Which files are regenerable and reasonably safe to clean?
- What could free a lot of space but requires a human decision?
- Which locations should a cleaner never touch?

Scanning and processing happen on the Mac. File names, paths, hashes, and
statistics are never uploaded to external services.

## Designed around safety

Every result belongs to one of three categories:

| Category | Meaning | Behavior |
|:--|:--|:--|
| 🟢 **SAFE** | Old, regenerable data under known roots | Shown first; cleaning requires explicit confirmation |
| 🟠 **REVIEW** | Potentially valuable or expensive-to-rebuild files | Nothing is preselected; the user chooses each item with a checkbox |
| ⚪️ **PROTECTED** | Personal data, credentials, code, apps, or system data | Statistics only; the app refuses to modify them |

> The main rule is simple: when in doubt, SAFE becomes REVIEW; when there is
> significant ambiguity, REVIEW becomes PROTECTED.

![Safety policy inside the app](./docs/screenshots/safety-policy.png)

## What it can analyze

### Safe, regenerable cleanup

- Old application caches in `~/Library/Caches`.
- Old user logs and diagnostic reports.
- Xcode DerivedData, documentation, and module caches.
- Simulator devices that `simctl` marks as unavailable.
- Items identified by Homebrew itself through `brew cleanup --dry-run`.
- npm, pnpm, and Python caches, reported conservatively when an official cleanup
  would be too broad to run with confidence.

Recent, open, non-user-owned, or post-scan-modified files are excluded or rejected
at confirmation time.

### Items that always require review

- Downloads, installers, disk images, and archives.
- Large or old files. **Old never means useless.**
- Local iPhone and iPad backups.
- Xcode Archives, Device Support, and installed runtimes.
- Docker images, containers, volumes, and build cache.
- Local Time Machine snapshots.
- Trash.
- `node_modules`, `.venv`, `venv`, `.next`, `build`, `dist`, and Gradle caches.
- Duplicates confirmed through size, partial hash, and full SHA-256.

The Developer view is enabled from its sidebar switch and groups Docker, Xcode,
project dependencies, and package caches away from personal storage. Docker
images are shown individually by tag and image ID. An explicitly selected image
can be removed through `docker image rm` only after typing the permanent-delete
confirmation; the app never uses `--force`, so Docker rejects images still used
by containers. Docker volumes, containers, build cache, snapshots, runtimes,
and other entries without an unambiguous direct action remain informational.

### Protected locations

The app refuses, among others:

```text
/System              /Library                 ~/.ssh
/bin                 /private                 ~/.aws
/sbin                /var                     ~/.config
/usr                 /Applications            .env files

Documents · Desktop · Pictures · Music · Mail · Messages · Safari
iCloud Drive · Dropbox · OneDrive · Google Drive
Library/Containers · Library/Group Containers · Git repositories
.app applications · media libraries · credentials
```

It does not modify signed bundles, remove Universal Binary architectures, or
recursively delete system directories.

## Usage flow

1. Open **Mac Cleaner Local**.
2. The app runs an initial read-only scan.
3. Review the summary and open SAFE, REVIEW, or PROTECTED to see exact paths.
4. For SAFE, inspect the plan and confirm cleanup.
5. For REVIEW, manually select the files you want.
6. Use **Move to Trash** as the normal option. Permanent deletion is limited to
   individual regular files and requires typing `DELETE`.
7. After an action, the report is invalidated and a new one must be generated.

Moving something to Trash is not counted as reclaimed space until Trash is emptied.

## Checks before every action

Immediately before touching an item, the central executor checks again:

- device, inode, size, and modification time;
- current owner;
- absence of symlinks anywhere in the path;
- membership in an allowed cleanup root;
- classification and exact match with the report held by Tauri;
- persistent exclusions and protected directories;
- that it is not `/`, the user's HOME, or a suspiciously broad path.

Paths are never concatenated into shell commands. REVIEW directories are moved only
through an atomic rename to `~/.Trash`; there is no cross-filesystem copy-and-delete
fallback.

## Audit trail

Each operation generates a JSON record in:

```text
~/.local/share/mac-cleaner/history/
```

The record includes the date, macOS version, action, original path, size,
classification, reason, and result. Reclaimed space is measured using available
storage before and after; it is not claimed by simply adding estimates.

```console
./mac-cleaner history
```

## Desktop app

The interface is built with **Tauri 2 + HTML/CSS/JavaScript** and follows a native
macOS aesthetic built around translucent layers, depth, system typography, and
controls with a clear visual hierarchy.

The local build is available at:

```text
~/Applications/Mac Cleaner Local.app
```

A DMG for Apple Silicon is also generated at:

```text
src-tauri/target/release/bundle/dmg/Mac Cleaner Local_0.2.0_aarch64.dmg
```

> The local build uses ad-hoc signing and is not notarized by Apple. Public
> distribution requires a Developer ID certificate and notarization.

## CLI

The Python engine can also be used from Terminal. Running `mac-cleaner` without a
subcommand **never deletes anything**.

| Command | Function |
|:--|:--|
| `./mac-cleaner` | Storage summary, equivalent to `scan` |
| `./mac-cleaner scan --developer --large` | Expanded scan of development and large files |
| `./mac-cleaner scan --details` | Show every candidate path |
| `./mac-cleaner large` | Large and old files in bounded locations |
| `./mac-cleaner duplicates` | Verified duplicates, starting with Downloads |
| `./mac-cleaner clean --dry-run` | Exact SAFE plan without modifying files |
| `./mac-cleaner clean` | Interactive SAFE cleanup; requires `CLEAN SAFELY` |
| `./mac-cleaner history` | Audit history |
| `./mac-cleaner ignore PATH` | Permanently exclude a path |

## Exclusions and configuration

Configuration lives at:

```text
~/.config/mac-cleaner/config.json
```

Paths, patterns, and entire categories can be excluded:

```console
./mac-cleaner ignore ~/Projects/important-client
./mac-cleaner ignore --pattern '*.keep-cache'
./mac-cleaner ignore --category 'App caches'
```

Age and size thresholds, as well as enumeration limits, are also configurable.
Exclusions are applied before cleanup candidates are created.

## Development

### Requirements

- macOS 12 or later.
- Python 3.10 or later.
- Rust and Cargo.
- Node.js and npm.
- Tauri 2 CLI, installed through the project dependencies.

No dependencies are installed automatically, and normal operation does not require
`sudo`.

### Run and build

```console
npm install
npm run dev
npm run build
```

### Tests

```console
PYTHONPATH=src python3 -m unittest discover -s tests -v
cargo check --manifest-path src-tauri/Cargo.toml
node --check frontend/app.js
```

Destructive tests use temporary fixtures exclusively. They include attempts against
`/`, HOME, `~/.ssh`, Documents, `/System`, post-scan changes, symlink escapes, and
names containing spaces, Unicode, newlines, metacharacters, and leading hyphens.

## Arquitectura

```text
macOS + filesystem + native tools
                  │
                  ▼
        read-only Python scanners
                  │
                  ▼
        immutable report with identities
                  │
                  ▼
     sealed state inside the Rust process
             │                 │
             ▼                 ▼
       paginated interface   exact selection
                                │
                                ▼
                   centralized revalidation
                                │
                                ▼
                     action + JSON audit
```

See [ARCHITECTURE.md](./ARCHITECTURE.md) for trust boundaries and internal safety
decisions.

---

<p align="center">
  <strong>Recovering less space is acceptable. Deleting something important is not.</strong>
</p>
