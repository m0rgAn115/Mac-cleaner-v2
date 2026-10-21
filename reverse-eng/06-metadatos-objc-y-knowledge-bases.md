# 06 · Metadatos ObjC y contratos de los knowledge bases

Sesión 2 (2026-10-15), con el **MCP de REA** ya conectado. Herramientas:
`open_binary` + `inspect_native_dispatch_metadata` (proveedor
`rea-workflow`, sin Ghidra/Hopper). Esto decodifica de la sección
`__objc_*` del binario las clases, selectores, **ivars con tipo** y protocolos,
incluidos los internos que no se exportan. No es decompilación: no hay
cuerpos de funciones ni constantes.

| Evidence | Framework | SHA-256 | Clases ObjC | ivars |
|:--|:--|:--|--:|--:|
| `20-dispatch-SystemJunkScanning.json` → `ev_c8e6a255c22280d0…` | SystemJunkScanning | `d51c6049315b` | 200 | 267 |
| `20-dispatch-LegacyScanningCore.json` → `ev_974afa6b2e3a6103…` | LegacyScanningCore | `039c086b0eac` | 42 | 36 |
| `20-dispatch-UninstallerScanning.json` → `ev_6366c56f6db6655d…` | UninstallerScanning | `49bc4bb24b82` | 122 | 239 |
| `20-dispatch-TrashJunkScanning.json` → `ev_742159a6248e84d3…` | TrashJunkScanning | `651c0d8fea28` | 14 | 13 |
| `20-dispatch-UnusedDiskImagesScanning.json` → `ev_b2da302a2603634d…` | UnusedDiskImagesScanning | `4b2931d90174` | 6 | 7 |
| `20-dispatch-DownloadsScanning.json` → `ev_4bfa9f182af11f22…` | DownloadsScanning | `1305c9496345` | 26 | 53 |

Resúmenes legibles en `dispatch/<Framework>.txt` (generados con
`tools/summarize_dispatch.py`). Cobertura reportada por REA: metadatos de
clase/método/ivar ObjC **completos**; metadatos Swift genéricos y async
**no soportados** (los ivars Swift salen sin tipo).

## 1. Qué contienen los knowledge bases (observado)

Los protocolos que el motor usa para consultar el `.cmmkb` revelan **qué
preguntas** le hace, sin necesidad de abrir el archivo:

| Protocolo | Métodos |
|:--|:--|
| `CMCachesKnowledgeBase` | `isIgnoreItem:`, `shouldPerformDeepSearchForItem:` |
| `CMLogsKnowledgeBase` | `isIgnoreItem:` |
| `CMSystemJunkKnowledgeBase` | `isIgnoreItem:`, `shouldIgnoreURL:` |
| `CMFileIgnoreKnowledgeBase` | `isIgnoreItem:` |
| `CMMobileBackupsKnowledgeBaseType` | `isIgnoreItem:`, `shouldIgnoreURL:`, `shouldIgnoreDeviceID:`, `shouldIgnoreBrokenBackups` |
| `CMXcodeJunkKnowledgeBaseType` | `shouldIgnoreURL:`, `shouldIgnoreSimulatorRuntime:` |
| `CMApplicationLanguagesKnowledgeBase` | `isPathIgnored:`, `isBundleIdIgnored:`, `isLanguageIgnored:`, `isLanguageIgnored:forApplication:` |
| `CMUniversalBinariesKnowledgeBaseType` | `shouldIgnoreApplication:` |
| `CMUnusedDiskImagesKnowledgeBaseType` | `shouldIgnoreURL:` |
| `CMDownloadsScanningKnowledgeBase` | `shouldIgnoreApplication:`, `shouldIgnoreAccount:ofApplication:`, `shouldIgnoreURL:` |
| `CMUninstallerKnowledgeBaseType` | `isAppIgnoredWithBundleId:`, `isAppProtectedWithBundleId:`, `isAggressorBundleID:`, `isDirectoryExcludedButChildrenNot:`, `isIgnoreOrSystemItemFileWithPath:`, `bundleIDsForFileURL:`, `applicationNameFor:`, `additionalFilesForApplicationName:bundleId:`, `isApplicationIgnoredWithApplication:`, `isPluginIgnoredWithPlugin:` |

**Conclusión (inferida con buena confianza):** en las áreas de limpieza, el
knowledge base es sobre todo una **lista de exclusiones**. *Dónde* buscar está
en el código (cada `CM*ScanTask` conoce su directorio); el KB responde “¿esto
lo ignoro?”. Las únicas consultas positivas son:

- `shouldPerformDeepSearchForItem:` → qué caches recorrer en profundidad en vez
  de tratarlas como una sola carpeta.
- `bundleIDsForFileURL:` y `additionalFilesForApplicationName:bundleId:` en el
  desinstalador → mapean archivos sueltos a apps y añaden archivos conocidos
  de cada app.
- `isDirectoryExcludedButChildrenNot:` → excluir un directorio pero seguir
  mirando sus hijos (útil para `Application Support/<vendor>/`).

Implicación de diseño: una lista de reglas equivalente no necesita describir
todas las caches; basta con **ubicaciones fijas + una denylist + mapeos
archivo→bundle ID**.

## 2. Predicados de filtrado (`LegacyScanningCore`, observado)

`CMPredicate { shouldIgnoreObject:, supportedTypes }` con implementaciones:

- `CMCompoundPredicate(type, subpredicates)` (AND/OR)
- `CMFileExistencePredicate`
- `CMFileIgnorePredicate(knowledgeBase)`
- `CMFileIsReachablePredicate`
- `CMFileNamePredicate(pattern)`
- `CMFileSizePredicate(limit)`

**No hay predicado de fecha/antigüedad** en las clases ObjC. La autoselección
de caches vive en `CMCacheScanTask.isResultAutoselectable`, un método **por
tipo de tarea**: `CMGradleCacheScanTask` lo sobrescribe. **Inferido**:
CleanMyMac decide la autoselección **por categoría** y no por antigüedad del
archivo, al menos en el código ObjC. Puede haber lógica de fechas en Swift que
este método no ve (*desconocido* sin decompilar).

## 3. Caches (observado)

- `CMCacheScanTask{cachesDirectoryURL, knowledgeBase, privilegedOperationsPerformer}`
  con `contentOfCachesDirectoryURL`, `_performDeepSearchForURL:withFilterPredicate:`,
  `_fileSizeAtURL:cancellationFlag:`.
- Subclases que solo cambian el directorio: `CMSandboxContainersCachesScanTask`,
  `CMDarwinUserCachesScanTask`, `CMCoreSymbolicationdCacheScanTask`,
  `CMSystemCachesScanTask`, `CMGradleCacheScanTask`.
- `CMCacheGroupModel(identifier, isAutoselected)` agrupa por app.

## 4. Desinstalador: tipos de recurso por app (observado)

`CMResourcesFetcher` compone una lista de *fetchers*, uno por tipo de recurso:

| Fetcher | Recurso (inferido por nombre) |
|:--|:--|
| `CMLibraryPathsFetcher` | `~/Library/<subdir>/<bundleID o nombre>` |
| `CMSupportingFilesFetcher` | Application Support |
| `CMCachesFetcher` | Caches |
| `CMPreferencesFilesFetcher` | Preferences (`.plist`, ByHost) |
| `CMApplicationContainerFetcher` | `~/Library/Containers/<id>` |
| `CMExtraFilesForSandboxedApplicationFetcher` | Group Containers y otros de apps sandboxed |
| `CMApplicationSavedStateFetcher` | Saved Application State |
| `CMCookiesFetcher` | `~/Library/Cookies/<id>.binarycookies` |
| `CMLogsFetcher`, `CMCrashLogsFetcher` | Logs, DiagnosticReports |
| `CMTempFilesFetcher` | temporales |
| `CMLaunchDemonsFetcher`, `CMLoginItemsFetcher` | LaunchAgents/Daemons, login items |
| `CMPluginsFetcher`, `CMPluginResourcesFetcher`, `CMPDFServicesFetcher` | plugins, PDF Services |
| `CMApplicationHelpFetcher` | Help books |
| `CMDockIconFetcher` | icono en el Dock |
| `CMDownloadFilesFetcher` | descargas asociadas (inferido: DMG/ZIP del instalador) |
| `CMReceiptFetcher` | recibos de `pkgutil` |
| `CMResourcesFromKnowledgeBaseFetcher` | archivos extra que conoce el KB |

`CMApplicationInfoType` expone `lastUsedDate`, `isFromAppStore`,
`sandboxContainerPath`, `securityApplicationGroupIdentifiers`,
`privilegedExecutables`, `isRestricted` y `signedWithAgressorCountryCertificate`.

`LeftoversFetcher` (Swift) tiene `associatedBundleIDsProvider`,
`sharedApplicationTemplate` y `userApplicationTemplate`. **Inferido**: busca
sobras con plantillas de ruta, separadas para el dominio de usuario y el
compartido (`/Library`), y descarta bundle IDs asociados a apps que siguen
instaladas.

### Pregunta #13 resuelta: `isAggressor`

`CMUninstallerKnowledgeBaseType.isAggressorBundleID:` y
`CMApplicationInfoType.signedWithAgressorCountryCertificate` muestran que
“aggressor” marca apps de desarrolladores de un país agresor, por bundle ID o
por certificado de firma. Es una política del producto y **no tiene relación
con la seguridad de la limpieza**. No hay que replicarlo.

## 5. Papeleras, DMG y Descargas (observado)

- `CMTrashesScanTask(paths, includeICloudTrashes)` con `_trashURLs` y
  `_mobileDocumentsTrashes`. La papelera de iCloud Drive se maneja aparte.
- `CMMountedTrashesScanTasksFactory.isVolumeAtMountURLCleanable:` filtra los
  volúmenes montados antes de escanear su papelera: exige ruta bajo `/Volumes/`,
  volumen *browsable*, local y no de solo lectura (confirmado en 09 §1.2).
- `CMUnusedDiskImagesScanTask(searchController: CMMetadataSearchController)`:
  la búsqueda de DMG usa **Spotlight** (`NSMetadataQuery`), no un recorrido del
  disco.
- Chrome: `CMChromeDownloadItem{downloadPath, start/endTime, fullyDownloaded}`
  y `compareAndRemoveDuplicates:`. La decompilación (09 §3.3) muestra que el
  escaneo **no** filtra por `fullyDownloaded` y nunca preselecciona.
