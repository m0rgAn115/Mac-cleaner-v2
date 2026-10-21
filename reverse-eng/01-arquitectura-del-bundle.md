# 01 · Arquitectura del bundle

Evidence: inventario `ev_633fec5c…`, grafo Apple `ev_c40ebeee…`, plists
`ev_88c3942e…` / `ev_f547a1c6…` / `ev_fb093cc8…`, firma `ev_895d9e52…`.

## Anatomía (observado)

```text
CleanMyMac_5_MAS.app
├── Contents/MacOS/CleanMyMac_5_MAS        ← ejecutable casi vacío (2 exports): todo vive en frameworks
├── Contents/Frameworks/                   ← 285 bundles "framework" contando versiones; ~120 frameworks únicos
├── Contents/Library/LoginItems/
│   ├── CleanMyMac_5_MAS_HealthMonitor.app ← agente en barra de menú (LSUIElement), monitoreo de salud
│   └── CleanMyMac_5_MAS_Menu.app          ← menú (LSUIElement), URL scheme cleanmymac5-menu
├── Contents/Resources/
│   ├── info.cmmkb (287 KB)                ← "knowledge base": blob opaco/cifrado, NO analizado
│   ├── userInfo.cmmkb (2 KB)              ← opaco
│   ├── 15 resource bundles (Features_*, GTM*, SwiftyDropbox, SwiftProtobuf…)
│   └── *.lproj, Assets.car
└── _MASReceipt
```

- No hay `Contents/Library/LaunchServices` (sin helper SMJobBless) ni XPC
  services embebidos: `privileged_helpers = []` en el grafo Apple.
- 876 symlinks (estructura `Versions/A` de frameworks).
- Sólo 2 “runtime families” detectadas y 0 puentes JS↔nativo: es una app
  100 % nativa (Swift + Objective-C), sin Electron.

## Sandbox y permisos (observado, `ev_895d9e52…`)

Entitlements del ejecutable principal:

| Entitlement | Significado para un limpiador |
|:--|:--|
| `com.apple.security.app-sandbox` | Corre sandboxed: no puede leer `~/Library` libremente |
| `files.user-selected.read-write` | Accede sólo a lo que el usuario elige en un panel de apertura |
| `files.bookmarks.app-scope` | Guarda bookmarks de seguridad para recordar ese acceso |
| `personal-information.photos-library` | Lee la fototeca (caches/miniaturas de Photos) |
| `network.client` / `network.server` | Red (updates, nube, analítica) |
| `application-groups` + `keychain-access-groups` (incl. Moonlock) | Comparte estado con login items y con el motor antimalware Moonlock |

- Hardened runtime activado. Team ID `S8EX82NJP6`.
- **Inferido**: los símbolos `homeFolderSandboxAccessProvider` y
  `applicationsFolderSandboxAccessProvider` (en `SmartCareModuleBuilder`,
  `JunkCleanupModuleBuilder`, `SpaceLensModuleBuilder`) indican que la app pide
  al usuario seleccionar su carpeta Home y `/Applications` una vez y guarda el
  bookmark. Junto con *Full Disk Access* (`fullDiskAccessPermissionProvider` en
  `SpaceLensScanTasksFactory`, `isFDAGranted:` en strings de Uninstaller), es su
  forma de salir del sandbox.
- Info.plist declara textos de uso para Documentos, Escritorio, Descargas,
  Fotos, Contactos, Calendarios, Recordatorios, Música y Ubicación: cada uno
  es una carpeta/servicio TCC que su escaneo toca.

Los login items **no** tienen `com.apple.security.app-sandbox` declarado en su
Info.plist (los entitlements de login items no se inspeccionaron:
*desconocido*). HealthMonitor tiene
`LSFileQuarantineExcludedPathPatterns = ~/Library/Application Support/*`.

## Mapa de frameworks por capa (observado por nombre, rol inferido)

| Capa | Frameworks |
|:--|:--|
| UI / navegación | `MainAppUI`, `NavigationUI`, `ModuleUI`, `SharedUI`, `DesignSystem`, `LegacyUI`, `SettingsUI`, `DataManagerUI`, `SpaceLensUI`, `CloudStorageUI`, `TerminatorUI`, `AssistantUI`, `RiveRuntime`, `SnapKit` |
| Módulos (features) | `SmartCareModule`, `JunkCleanupModule`, `ApplicationsModule(+Domain)`, `PerformanceModule`, `ProtectionModule`, `SpaceLensModule`, `CloudStorageModule`, `OrganizeModule`, `ToolboxModule`, `AssistantModule` |
| Escaneo | `ScanningCore`, `LegacyScanningCore`, `LegacyScanningWrapperCore`, `SystemJunkScanning`, `TrashJunkScanning`, `MailJunkScanning`, `DownloadsScanning`, `UnusedDiskImagesScanning`, `UninstallerScanning`, `UpdaterScanning`, `PrivacyScanning`, `PerformanceScanning`, `SpaceLensScanning`, `OrganizeScanning`, `CloudStorageScanning`, `Malware*` |
| Limpieza / modelo | `CleaningCore`, `NodesCore` |
| Servicios de sistema | `FileManagerService`, `ApplicationsService`, `ApplicationsTerminator`, `PerformanceService`, `PrivacyService`, `PrivilegedOperationsPerformerService`, `PrivilegedRoutines`, `PermissionsKit`, `SystemPermissionsKit`, `PANEngine`, `PantherEngineService` |
| Persistencia / config | `DatabaseKit` (+`FMDB`, SQLite con passphrase), `PreferencesStorage`, `SharedPreferences`, `RemotePreferences`, `MPTweaks` |
| Negocio / telemetría | `ActivationService`, `AnalyticsService`, `StatisticsService`, `MacPawGrowthBookWrapper`, `MacPawOpenFeatureWrapper`, `RateFlow`, `AnnouncementsService` |
| Nube | `GoogleDriveService`, `DropboxService`, `MicrosoftService` (+`MSAL`), `CloudStorageService` |
| Actualización | `Sparkle`, `SparkleUpdaterService`, `MASUpdaterServiceAPI` |

**Patrón clave (inferido)**: cada feature = `XModule` (UI + coordinator +
builder) + `XScanning` (fábrica de tareas + modelos Codable) + servicios
compartidos inyectados. `LegacyScanningCore` contiene clases Objective-C
`CM*` (predicados de archivo, modelos de árbol) envueltas en Swift por
`LegacyScanningWrapperCore`: hay código heredado de CleanMyMac X conviviendo con
la reescritura Swift.
