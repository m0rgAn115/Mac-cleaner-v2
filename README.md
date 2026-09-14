# Mac Cleaner Local

Conservative macOS storage analysis and explicitly confirmed cleanup, implemented
with Python's standard library and a native Tauri desktop interface.

The default command and every scan are read-only:

```console
./mac-cleaner
./mac-cleaner scan --developer --large
./mac-cleaner scan --details
./mac-cleaner large
./mac-cleaner duplicates
./mac-cleaner clean --dry-run
./mac-cleaner clean
./mac-cleaner history
./mac-cleaner ignore ~/path/to/exclude
```

`clean` prints the complete SAFE plan first and requires typing `LIMPIAR SEGURO`
in an interactive terminal. The desktop app provides the primary workflow:

- SAFE: inspect exact paths, press **Limpiar lo seguro**, acknowledge the plan,
  then allow the executor to revalidate each item.
- REVIEW: nothing is preselected. Choose explicit checkboxes; moving to Trash is
  the normal action. Permanent deletion is limited to individual regular files
  and requires typing `ELIMINAR`.
- PROTECTED and advisory-only entries have no action control.

Every attempted operation writes a full JSON audit under
`~/.local/share/mac-cleaner/history/` and reports disk availability measured
before and after. Moving something to Trash normally reports zero reclaimed bytes
until the Trash is emptied.

## Safety policy

- SAFE means old, user-owned, closed, regenerable files under a narrow independent
  allowlist, or a cleanup plan produced and revalidated by Homebrew/simctl.
- REVIEW means potentially useful data. Supported direct actions are narrowly
  limited to Downloads/Public/Movies files, Xcode archives/device support, local
  device backups, Gradle caches, and recognized generated project directories.
- PROTECTED means statistics only: system roots, credentials, Git source, app and
  media bundles, personal folders, cloud storage, Mail, Messages, Safari, and app
  containers.

The executor never follows symlinks, never invokes a shell for paths, refuses
cross-filesystem copy-and-delete fallbacks, re-stats every object, and invalidates
the entire scan after an action.

Configuration is stored at `~/.config/mac-cleaner/config.json` and supports ignored
paths, patterns, categories, and configurable age/size thresholds.

## Development

```console
PYTHONPATH=src python3 -m unittest discover -s tests -v
npm install
npm run dev
npm run build
```

Tests execute deletion only inside temporary fixtures. They cover `/`, home,
Documents, system roots, credentials, identity changes, symlink escapes, broad
metadata roots, Git projects, directories, and unusual filenames.
# Mac-cleaner
