# 02 · Catálogo de escaneo

Fuente: exports demangleados en `symbols/<Framework>.txt` y literales en
`strings/<Framework>.paths.txt`. Los nombres de categoría son **observados**
(nombres de métodos de fábrica o clases `CM*ScanTask`); las rutas marcadas
“literal” aparecen tal cual en el binario; el resto de rutas son conocimiento
público de macOS y se marcan como **inferidas**.

## Patrón común

Cada framework expone una `*ScanTasksFactory` cuyos métodos devuelven una tarea
por categoría. La mayoría recibe `knowledgeBase:` → las reglas concretas vienen
del `.cmmkb`, no del código. Cada modelo de resultado es `Codable` y casi todos
tienen `url`, `size` e **`isAutoselected`**.

---

## System Junk — `SystemJunkScanning` (`ev_0e69247b…`)

Métodos de `SystemJunkScanTasksFactory` (observados), con lo que implican:

| Categoría | Tarea / clase | Notas |
|:--|:--|:--|
| User cache | `userCache(knowledgeBase:privilegedOperationsPerformer:)`, `CMUserCachesCompoundTask`, `CMUserCachesScanTask` | `CachesKnowledgeBase` decide qué es cache |
| System cache | `systemCache(…privilegedOperationsPerformer:)`, `CMSystemCachesCompoundTask` | Necesita agente privilegiado |
| Darwin user caches | `CMDarwinUserCachesScanTask`; string `darwinUserCaches` | Inferido: `/var/folders/…/C` (`getconf DARWIN_USER_CACHE_DIR`) |
| Caches de apps sandboxed | `CMSandboxContainersCachesScanTask`; literales `Data/Library/Caches`, `Data/Library/Logs` | `~/Library/Containers/<id>/Data/Library/Caches` |
| Caches específicas de apps | `CMHardcodedPathCacheScanTask`, `CMElectronAppsCacheScanTask`, `CMGradleCacheScanTask`, `CMSpotifyCacheScanTask`, `CMDropboxCacheScanTask`, `CMCoreSymbolicationdCacheScanTask`, `CMAppStoreDownloadsCacheScanTask` | Literales: Adobe Media Cache, Spotify PersistentCache, Telegram, WeChat, QQMusic, Youku, Tencent Video, Photos Desktop |
| User logs | `userLogs`, `CMUserLogsScanTask`, `CMUserLogsProvider` | |
| System logs | `systemLogs(…privileged…)`, `CMSystemLogsScanTask`, providers `CMAppleLogsProvider`, `CMDiagnosticLogsProvider`, `CMPrivateLogsProvider`, `CMSandboxLogsProvider`, `CMLocalLogsProvider`, `CMQuarantineLogsProvider` | `LogsModel.LogType` enum; literal `QuarantineEventsV2` |
| Language files | `applicationLanguages`, `CMApplicationLanguagesScanTask`, `ApplicationLanguageModel{appBundleId,isoCode,files}` | Quita `.lproj` no usados. **Rompe firmas de código**: no replicar |
| Universal binaries | `makeUniversalBinaries`, `UniversalBinaryThinner` (usa `lipo`) | Adelgaza binarios fat. **Rompe firmas**: no replicar |
| Broken preferences | `brokenPreferences`, `BrokenPreferencesRemover(prefsdManager:)` | Plists corruptos en `~/Library/Preferences`; usa `/usr/bin/defaults` (literal) y notifica a `cfprefsd` |
| Broken startup items | `brokenStartupItems`, `CMBrokenLaunchdAgentsItemsScanTask`, `CMBrokenLoginItemsScanTask`, `BrokenStartupItemModel.ItemType` | LaunchAgents cuyo ejecutable no existe; string `_isAgentInPathOwnedByAnyApp:` |
| Document versions | `documentsVersions`, `CMDocumentVersionsScanTask`, `CMDocumentVersionsSelectionRule` | Versiones antiguas (`/.DocumentRevisions-V100`); tipos iWork literales |
| Deleted users | `deletedUsers`, `CMDeletedUsersScanTask` | Literal `/Library/SystemMigration/History`; inferido `/Users/Deleted Users` |
| iOS backups | `mobileBackups`, `CMMobileBackupsTask`, `MobileBackupsModel{date,latest}` | Marca el backup más reciente (`latest`) |
| Xcode DerivedData | `xcodeDerivedData` | |
| Xcode Archives | `xcodeArchives` | |
| Xcode module cache / docs | `moduleCache`, `moduleDocumentation` | literal `Module Caches`, `Xcode Caches` |
| Device support | `iOSDeviceSupport`, `macOSDeviceSupport`, `watchOSDeviceSupport`, `tvOSDeviceSupport` | |
| Device logs | `iosDeviceLogs`, `CMXcodeDeviceLogsScanTask` | literal `iOS Device Logs` |
| Simulators | `xcodeSimulators`, `XcodeSimulatorRemover.remove(uuid:)`, `CMXcodeSimulatorControl` | literal ruta de `simctl` y `xcrun` |
| Simulator runtimes | `simulatorRuntimes`, `XcodeSimulatorRuntimeRemover`, `CMSimulatorRuntimesFetcher` | literal `com.apple.CoreSimulator.SimRuntime.` |
| CoreSimulator cache | `coreSimulatorCache` | |
| Xcode downloaded runtimes | `CMXcodeDownloadedRuntimesScanTask` | |

## Papeleras — `TrashJunkScanning` (`ev_73c0da88…`)

- `makeSystemTrashScanTask()` → `~/.Trash`.
- `makeMountedVolumesTrashScanTasks()` → `/Volumes/*/.Trashes/<uid>`
  (`CMMountedTrashesScanTask(volumeURL:)`).
- `makeMailTrashScanTasks()` → adjuntos en la papelera de Mail.
- `TrashFileModel{isCloudFile, isApplicationFromAppStore}` y
  `CMTrashesScanTask(paths:includeICloudTrashes:)`; `FileManagerProvider`
  expone `iCloudTrashDirectories` y `mobileDocumentsTrashDirectories`.

## Adjuntos de correo — `MailJunkScanning` (`ev_d2c4e2c7…`)

- `mailAppAttachments(knowledgeBase:)`; `MailAppJunkModel.AttachmentModel{copies}`
  → detecta **copias** de adjuntos descargados.
- `SparkJunkModel` → también cliente Spark.

## Descargas — `DownloadsScanning` (`ev_15c6f8a4…`)

- Tareas por **origen**: `safariDownloadsTask`, `chromeDownloadsTask`,
  `slackDownloadsTask`. Leen el historial de descargas de cada app (claves
  `CMChromeDownloadItemKey*`, `CMSlackDownloadsHistoryKey*`; literal de la
  carpeta de storage de Slack).
- Agrupan por app → cuenta/perfil → ítem (`DownloadsApplicationModel →
  DownloadsAccountModel → DownloadsItemModel{creationDate,isAutoselected}`).
- Constante `kMoreThanMonthAgo` = **30 días** [O]. Solo Slack la usa para
  preseleccionar. Safari preselecciona solo descargas incompletas con Safari
  cerrado, y Chrome nunca (ver 09 §3).

## Imágenes de disco sin uso — `UnusedDiskImagesScanning` (`ev_511d1b12…`)

- `unusedDiskImagesTask()`; busca con Spotlight por UTI `com.apple.disk-image-udif`
  y usa `kMDItemPhysicalSize`.
- ⚠️ **Corregido en la sesión 3** (ver 09 §2): **no** comprueba si la app está
  instalada. Lista todos los DMG UDIF salvo los de Dropbox y los de la denylist,
  y **ninguno se preselecciona**.

## Desinstalador y sobras — `UninstallerScanning` (`ev_f1853b46…`)

- Tareas: `userApplications`, `systemApplications`, `mobileApplicationsScanTask`
  (inferido: apps iOS en Apple Silicon), `steamApplications`, `blizzardApplications`,
  `jetBrainsApplications`, `audioPluginsScanTask` (AU/VST/AAX, incl. Avid),
  **`leftoversScanTask`** (`LeftoversFetcher.fetchLeftovers()`).
- Filtros componibles: `CompoundApplicationFilter([ApplicationNameFilter,
  BundleIdentifierFilter, PluginNameFilter, Steam/Blizzard/JetBrainsFilter])`
  con `shouldIgnore(application:)`.
- Cada app es `UninstallerApplicationCore{appInfo, isSystem, isAggressor,
  resources}`. **Inferido**: `isAggressor` marca apps que el usuario no
  debería poder “desinstalar a medias”/apps conflictivas.
- Ubicaciones de recursos (literales): `Library/Application Support`,
  `Library/Caches`, `Library/Preferences`, `Library/Logs`, `Library/Cookies`
  (`~/Library/Cookies/%@.binarycookies`), `Library/Saved Application State`,
  `Logs/CrashReporter/%@.crash.log`, `Logs/DiagnosticReports/`,
  `Logs/HangReporter/%@/`, `/Library/PDF Services`,
  `/Library/Documentation/Applications`, `.com.apple.containermanagerd.metadata.plist`
  (para mapear Containers → bundle ID), y el Dock (`com.apple.dock`) para
  quitar el icono.
- Recibos de paquetes: `CMPackageManager findPackagesByBundleID:`,
  `_findReceiptResourcesForPackage:` → **inferido**: usa `pkgutil` receipts
  para hallar archivos instalados por `.pkg`.
- Launch agents asociados: `buildForLaunchAgentsWithKnowledgeBase:isFDAGranted:`.

## Descubrimiento de apps — `ApplicationsService` (`ev_edb70ac3…`)

Literal: una expresión regular que **excluye** rutas al buscar apps:
`/net`, `/tmp`, `/var`, `/cores`, `/private`, `/opt` (salvo Caskroom de
Homebrew), `/dev`, `/sbin`, `/bin`, `/etc`, `/usr`, `/Library`, `/System`
(salvo Finder), `/Developer`, `/Volumes`, apps dentro de otras `.app`, VMs
(`.pvm`, `.vmwarevm`). También consulta `/System/Applications`,
`/Library/ColorPickers`, `/Library/SystemExtensions` y lee el entitlement
`app-sandbox` de cada app.

## Actualizaciones — `UpdaterScanning` (`ev_c9c9f1ad…`)

- `UpdaterScanOptions` = `.mas | .sparkle`; `ApplicationUpdateSource` con
  `SparkleInstallationType{isApp,isDMG,isPKG}`; `canBeUpdatedProgrammatically`.
- Pide metadatos a un servicio propio (`appInfoNetworkService`,
  `UpdaterScanningMetadata{osVersion,cpuArch,lang}`). No replicable sin
  backend; alternativa abierta: leer `SUFeedURL` de cada app y consultar el
  appcast Sparkle directamente.

## Rendimiento / mantenimiento — `PerformanceScanning` + `PerformanceService`

- Login items (`makeLaunchServicesLoginItemsScanTask`) y launch agents
  (`makeLaunchAgentsScanTask`) con knowledge bases de “ignorar”.
- Tareas de mantenimiento (observadas): Flush DNS, Free up purgeable space,
  Free up RAM, Periodic scripts, Reindex Spotlight (`/usr/bin/mdimport`),
  Repair disk permissions, Speed up Mail, Thin local snapshots
  (`/usr/bin/tmutil`). La mayoría corre vía `privilegedAgent`.

## Space Lens — `SpaceLensScanning` (`ev_c7b9c6f0…`)

- Árbol `SpaceLensFileSystemEntity{path,size,isDirectory,isPurgeable,children,leavesCount}`.
- Progreso `ScanProgressValue{scannedSize,currentPath}`.
- Literales: `/System/Volumes/Data/`, `/private/var/vm` (swap), `/Library/Reminders`.
- **Observado**: modela explícitamente el **espacio purgeable** (`CMPurgeableSpaceEntity` en LegacyScanningCore).

## Organize (duplicados / similares) — `OrganizeScanning` (`ev_7311157c…`)

- `BatchBasedScanner(rules:)` con enumerador por lotes, pausa/reanudación.
- `IgnoreStatus` con niveles **`skipEnumeration`**, **`skipGrouping`**,
  **`skipHashing`**, evaluado con `IgnoreStatus.evaluate(withRules:forURL:)`.
- Reglas internas: `InternalIgnoreRules.default`, `.duplicatesSpecificRules`,
  `.similarImagesSpecificRules`, `.laofSpecificRules` (**inferido**: “large and
  old files”).

## Privacidad — `PrivacyScanning` (`ev_ac79d900…`)

Safari / Chrome / Firefox: historial, cookies, autofill, contraseñas,
historial de descargas, pestañas de última sesión, local storage, motores de
búsqueda; Recent Items (apps, documentos, servidores); permisos de apps
(lee `TCC.db`, literal); red Wi-Fi. Usa `databaseLockStorage` → **inferido**:
detecta si el navegador tiene la base de datos abierta antes de tocarla.

## Nube — `CloudStorageScanning` (`ev_47c2d18b…`)

iCloud, Dropbox, Google Drive, OneDrive: `isLinked`, `isLocal`; permite
**liberar copia local** (`FileManagerProvider.evictUbiquitousItem(at:)`).
