# 08 · Especificación funcional: System Junk de CleanMyMac

Este documento describe **cómo se comporta CleanMyMac 5.5.3** en el módulo
*System Junk* (cachés, logs, Xcode, backups iOS, preferencias y agentes rotos),
con el detalle suficiente para que otro equipo implemente una funcionalidad
equivalente **sin volver a hacer ingeniería inversa**.

- Fuente: decompilación con Ghidra 12.1.4 vía REA (slices arm64 en `thin/`).
- Solo se describe comportamiento; no se copia código.
- Etiquetas: **[O]** observado en pseudocódigo/literales · **[I]** inferido ·
  **[?]** desconocido.

Evidence principal (todas sobre `thin/SystemJunkScanning`, SHA-256
`b2b4d285…fce29`, salvo indicación):

| Bloque | Evidence |
|:--|:--|
| Cachés: tarea base, contenedores, búsqueda profunda | `ev_9851129d…`, `ev_665655d0…` |
| Fábricas de cachés y de logs, filtro de logs | `ev_8fa574fb…` |
| Proveedores de rutas de logs, `CMLogsScanTask.scan` | `ev_3b11f621…`, `ev_3de5177e…` |
| `CMPaths` (rutas base) — `thin/SharedObjcUtils` | `ev_47bb8f75…`, `ev_846f003b…` |
| Predicados — `thin/LegacyScanningCore` | `ev_d4a2d7b3…` |
| Cuarentena, preferencias rotas, agentes rotos, backups iOS | `ev_bfb80943…`, `ev_34e67211…`, `ev_ec74d601…` |
| Xcode (DerivedData, DeviceSupport, device logs) | `ev_f5725093…` |
| Xcode (Archives, module/doc caches, runtimes, simuladores) | `ev_c72e79be…` |

---

## 0. Conceptos transversales

### 0.1 Modelo de resultado
Cada categoría devuelve un árbol de ítems. Cada ítem tiene `url`, `size` y
**`autoselected`** (preselección en la UI). Los grupos contienen hijos; un grupo
vacío se descarta. **[O]**

### 0.2 Predicados de filtrado (semántica exacta) **[O]**
Un predicado responde `shouldIgnore(item) → bool`; `true` = **excluir**.

| Predicado | Excluye cuando… |
|:--|:--|
| `Name(pattern)` | `lastPathComponent == pattern` (igualdad exacta). `dsStore` = `.DS_Store` |
| `Size(limit)` | tamaño **> limit** (bytes; directorios = tamaño recursivo) |
| `IsReachable` | el recurso **existe** |
| `Existence` | el archivo **existe** |
| `Ignore(kb)` | la lista de exclusión contiene la ruta completa **o** el nombre |
| `Access` | no es directorio **y** no se puede abrir para escritura (`NSFileHandle forUpdating` falla) |
| `Compound.NOT(p)` | `p` no excluye |
| `Compound.AND(ps)` | **todos** excluyen |
| `Compound.OR(ps)` | **alguno** excluye |

### 0.3 Lista de exclusión (“knowledge base”)
Viene de un archivo propietario cifrado (`Resources/info.cmmkb`), fuera de
alcance. Para implementar algo equivalente basta una **denylist propia**
consultada por ruta completa y por nombre (ver 06 §1).

### 0.4 Cancelación, pausa y progreso **[O]**
Cada ítem hace: esperar si está en pausa → salir si se canceló → sumar progreso
→ procesar. Los tamaños se calculan con un medidor cancelable.

### 0.5 Edad de archivos
**[O] Ninguna categoría de System Junk decompilada aplica filtro de antigüedad**:
ni cachés, ni logs, ni Xcode, ni preferencias, ni backups. Los únicos
criterios de selección son la ubicación, la lista de exclusión, el tamaño y la
escribibilidad.

---

## 1. Rutas base (`CMPaths`) **[O]**

| Accesor | Ruta |
|:--|:--|
| `userCaches` | `~/Library/Caches` (no sandbox: `NSSearchPathForDirectoriesInDomains(Caches, User)`) |
| `allUsersCaches` | `/Library/Caches` |
| `darwinUserCaches` | `confstr(_CS_DARWIN_USER_CACHE_DIR)` (≈ `/var/folders/xx/…/C/`); si está sandboxed, quita el sufijo del contenedor |
| `coresymbolicationdCaches` | `/System/Library/Caches/com.apple.coresymbolicationd` |
| `gradleCaches` | `~/.gradle/caches` |
| `sandboxContainer` | `~/Library/Containers` |
| `sandboxGroupContainer` | `~/Library/Group Containers` |
| `userLogs` | `~/Library/Logs` |
| `localLogs` | `/Library/Logs` |
| `aslLogs` | `/var/log/asl/` |
| `privateLogs` | `/private/var/log` |
| `diagnosticsLogs` | `/private/var/db/diagnostics` |
| `diagnosticsMessagesLogs` | `/private/var/log/DiagnosticMessages` |
| `deletedUsersURL` | `/Users/Deleted Users` |
| `mobileBackupsURL` | `~/Library/Application Support/MobileSync/Backup/` (resolviendo symlinks) |
| `xcodeSupportURL` | `~/Library/Developer/Xcode` |
| `derivedData` / `archives` / `xcodeDocumentationCache` | `<xcodeSupport>/DerivedData`, `/Archives`, `/DocumentationCache` |
| `iOSDeviceSupport` / `macOSDeviceSupport` / `iOSDeviceLogs` | `<xcodeSupport>/iOS DeviceSupport`, `/macOS DeviceSupport`, `/iOS Device Logs` |
| `xcodeInstalls` | `<xcodeSupport>/Installs` |
| `coreSimulatorCachesURL` | `<coreSimulator>/Caches` (`~/Library/Developer/CoreSimulator/Caches` [I]) |

---

## 2. Cachés

### 2.1 Composición **[O]**
- **User caches** (compuesto) = tareas planas
  `[UserCaches, DarwinUserCaches, SandboxContainersCaches]` + tareas
  personalizadas `[ElectronApps, HardcodedPath]` + tareas agrupadas por nombre
  `{"com.getdropbox.dropbox": Dropbox, "com.spotify.client": Spotify,
  "com.apple.appstore": AppStoreDownloads, "Gradle": Gradle}`.
- **System caches** (compuesto, requiere agente privilegiado) =
  `[SystemCaches (/Library/Caches), CoreSymbolicationd]`.

### 2.2 Algoritmo común de una tarea de caché **[O]**
1. Listar los **hijos directos** del directorio de caché (con
   `contentsOfDirectory`). Para contenedores sandboxed: unión de
   `~/Library/Containers/*/Data/Library/Caches/*` (07 #10).
2. Filtro = `OR(Name(.DS_Store), Ignore(kb))`.
3. Por cada hijo no excluido:
   - si `kb.shouldPerformDeepSearch(nombre)` → bajar **un nivel**: cada nieto no
     excluido es un ítem dentro de un grupo con el nombre del hijo; si el grupo
     queda vacío, se descarta;
   - si no → un solo ítem con el **tamaño recursivo** del hijo.
4. **Descartar tamaño 0** salvo que el agente privilegiado esté autorizado.
5. `autoselected = isResultAutoselectable` de la tarea: **YES** para todas las
   cachés, **NO solo para Gradle**.

### 2.3 Cachés de apps concretas (rutas literales) **[O]**
`CMHardcodedPathCacheScanTask` tiene grupos fijos (Telegram, Telegram Lite
MAS/Site, WeChat, QQLive, QQMusic, Youku, Adobe, caché de migración del sistema,
caché de Photos Desktop). Rutas literales del binario:

- `~/Library/Application Support/Adobe/Common/Media Cache Files`
- `~/Library/Application Support/Spotify/PersistentCache/Storage`
- `~/Library/Application Support/Telegram Desktop/tdata/user_data`
- `~/Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data`
- `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram`
- `~/Library/Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0`
- `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9`
- `~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic`
- `~/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video`
- `~/Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE`
- `/Library/SystemMigration/History` (caché de migración)

Subcarpetas exactas y preselección de cada una: ver **12 §2** (todas NO salvo Photos).

### 2.4 Electron **[O nombres / I lógica]**
`CMElectronAppsCacheScanTask` recorre las apps escaneadas, comprueba si cada una
tiene caché Electron (`_containsCacheForApplication:`) y calcula su URL en
`~/Library/Application Support/<app>/…` (`_electronCacheURLForApplication:`).
Detalle exacto en **12 §1**: solo `Application Support/<App>/Cache`, preseleccionado.

---

## 3. Logs

### 3.1 Composición **[O]**
- **User logs** = `[UserLogs, SandboxLogs, QuarantineLogs]`.
- **System logs** = `[LocalLogs, AppleLogs (ASL), PrivateLogs]` +
  `DiagnosticLogs` **solo si** `allowPotentiallyUnsafeOperations = YES`.

### 3.2 Fuentes de rutas **[O]**
| Tarea | Entradas |
|:--|:--|
| UserLogs | hijos de `~/Library/Logs` |
| SandboxLogs | hijos de `~/Library/Containers/*/Data/Library/Logs` |
| QuarantineLogs | dos archivos: `systemQuarantinePathV2` y `systemQuarantinePath` [O]; por los literales del binario son `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` y `…QuarantineEvents` [I] |
| LocalLogs | hijos de `/Library/Logs` |
| AppleLogs | `/var/log/asl/` (el directorio entero) |
| PrivateLogs | rutas conocidas dentro de `/private/var/log` + hijos cuyo nombre encaje en patrones conocidos |
| DiagnosticLogs | `/private/var/db/diagnostics` (el directorio entero) |

Listas exactas de nombres y patrones en **12 §3**. Literales de PrivateLogs **[O]**: `DiagnosticMessages`, `cups`, `daily.out`, `weekly.out`,
`monthly.out`, `system.log`, `install.log`, `wifi.log`, `fsck_hfs.log`,
`fsck_apfs.log`, regex `system.log.\d.gz`, `wifi.log.\d.bz2`. También
aparecen `CrashReporter`, `HangReporter` y `DiagnosticReports`.

### 3.3 Filtros por tarea **[O]**
| Tarea | Excluir si… (OR de) |
|:--|:--|
| User, Sandbox, Local | `.DS_Store` · **tamaño ≤ 10 KB** · en la denylist · no escribible |
| Quarantine | **no** (existe **y** tamaño > 0) · en la denylist · no escribible |
| Private | **no** (existe **y** tamaño > 10 KB) · en la denylist · no escribible |
| Apple (ASL), Diagnostic | en la denylist · no escribible |

10 KB = `0x2800` = 10 240 bytes.

### 3.4 Algoritmo **[O]**
1. Obtener las entradas de la fuente. Si hay error, el resultado queda vacío.
2. Por cada entrada no excluida:
   - **archivo** → un ítem con su tamaño;
   - **directorio** → recorrido **recursivo** de todos sus archivos; cada
     archivo no excluido es un hijo; si no queda ninguno, se descarta.
3. Todos los ítems de log: **`autoselected = YES`**.
4. **Sin filtro de edad.**

### 3.5 Borrado **[O símbolos]**
`LogsRemover(privilegedAgent, fileRemover, authorizeAgentBlock).removeLog`: usa el
agente privilegiado para las rutas de sistema. Los eventos de cuarentena son
bases SQLite: **[I]** se vacían o se borran, no se truncan línea a línea.

---

## 4. Preferencias rotas **[O]**

- Fuente: hijos directos de `~/Library/Preferences` (sin ocultos, sin descender).
- Primero se aplica `kb.shouldIgnoreURL`.
- Un archivo se considera **roto** si cumple **todo**:
  1. existe;
  2. su nombre **no** empieza por `.`;
  3. extensión `plist` (sin distinguir mayúsculas);
  4. la ruta **no** contiene `.lockfile`;
  5. tamaño > 0;
  6. **no** es inmutable (`NSFileImmutable` = false);
  7. al parsearlo con CoreFoundation (`CFPropertyListCreateWithStream`) el
     resultado es nulo **o** `CFPropertyListIsValid` falla.
- Nombre mostrado: el nombre de archivo hasta el primer `.` (búsqueda hacia atrás).
- **`autoselected = YES`**.
- Borrado: `BrokenPreferencesRemover(prefsdManager)` — **[I]** notifica a
  `cfprefsd` para que no reescriba la caché en memoria.

---

## 5. Login items y LaunchAgents rotos **[O]**

Un LaunchAgent está **roto** si:
1. Ejecutable = `Program`, o si no existe, `ProgramArguments[0]`.
2. Si hay `WorkingDirectory` y el ejecutable no empieza por `/`, se concatena.
3. Se normaliza la ruta y se expande `~`.
4. Si la ruta es nula → **roto**.
5. Si la ruta está restringida para lectura (algún padre), se comprueba con el
   agente privilegiado. **Si no está autorizado, NO se marca como roto.**
6. Si el ejecutable **existe** → no está roto.
7. Si no existe pero su nombre (`lastPathComponent`) coincide con el ejecutable
   de alguna **app escaneada** → no está roto (la app lo reinstalará).
8. En otro caso → **roto**.

`BrokenStartupItemModel.ItemType` distingue login items de launch agents;
`BrokenStartupItemRemover(performerService)` los elimina. Preselección: **SÍ** (12 §4).

---

## 6. Backups de iOS **[O]**

1. Listar hijos de `mobileBackupsURL` (opciones 7: sin ocultos, sin descender,
   sin contenido de paquetes); descartar los que estén en la denylist por nombre.
2. Para cada backup, leer `Info.plist`:
   - sin `Device Name` → **backup roto**, salvo que la denylist incluya “Broken
     Backups” o `shouldIgnoreBrokenBackups`;
   - con nombre → agrupar por dispositivo (`Device Name` + `Product Type`),
     salvo que la denylist ignore ese dispositivo.
3. Por dispositivo: fecha = `Status.plist:Date`, y si falta,
   `Info.plist:Last Backup Date`. Orden **descendente por fecha**.
   - El **primero** (más reciente): `latest = YES`, **`autoselected = NO`**.
   - Los demás: `latest = NO`, **`autoselected = YES`**.
4. Backups rotos: grupo aparte, **`autoselected = YES`**.

---

## 7. Xcode **[O]**

| Categoría | Raíz | Unidad de ítem | Autoselección |
|:--|:--|:--|:--|
| DerivedData | `~/Library/Developer/Xcode/DerivedData` | cada hijo directo (sin ocultos) | **YES**, salvo `ModuleCache.noindex` y `SymbolCache.noindex` → **NO** |
| Archives | `…/Archives` | cada archivo `.xcarchive` | **NO** (grupo y archivos) |
| iOS/macOS/watchOS/tvOS DeviceSupport | `…/<plataforma> DeviceSupport` | cada versión (hijo directo) | **NO** |
| iOS Device Logs | `…/iOS Device Logs` | el directorio entero | **YES** |
| Module caches | 3 ubicaciones: `org.llvm.clang`, `org.llvm.clang.<usuario>`, `com.apple.dt.xcode` (ModuleCache) | cada ubicación existente | **NO** |
| Documentation cache | `…/DocumentationCache` | cada subelemento (aplanado) | **NO** |
| Simulator runtimes descargados | runtimes de CoreSimulator del sistema (vía fetcher) | cada runtime | **NO** |
| Simuladores | dispositivos de `xcrun simctl list` (JSON) agrupados por runtime | cada dispositivo existente en disco | **YES solo si no está disponible** (12 §4) |
| CoreSimulator cache | `~/Library/Developer/CoreSimulator/Caches` | el directorio entero | **NO** |

Borrado: simuladores con `XcodeSimulatorRemover.remove(uuid:)` y runtimes con
`XcodeSimulatorRuntimeRemover.remove(uuid:)`, ambos vía `simctl` (literal de la
ruta de `simctl` y de `xcrun`). **No se borran carpetas de simuladores a mano.**

---

## 8. Otras categorías de System Junk (resumen)

| Categoría | Estado | Nota |
|:--|:--|:--|
| Usuarios eliminados (`/Users/Deleted Users`) | [O] | Solo archivos `.dmg`, no preseleccionados (12 §4) |
| Versiones de documentos | [O] | Regla de 4 horas; nunca la más nueva ni la más antigua (12 §5) |
| Archivos de idioma | [O] símbolos | **No recomendable**: rompe la firma de código |
| Binarios universales (`lipo`) | [O] símbolos | **No recomendable**: rompe la firma de código |

---

## 9. Tabla resumen de preselección

| Categoría | Preseleccionado |
|:--|:--|
| Cachés de usuario, de sistema, Darwin, contenedores, Electron, Spotify, Dropbox, App Store, rutas fijas | **Sí** |
| Caché de Gradle | No |
| Logs (todas las fuentes) | **Sí** (solo > 10 KB donde aplica) |
| Preferencias rotas | **Sí** |
| Backup iOS más reciente por dispositivo | No |
| Backups iOS anteriores y backups rotos | **Sí** |
| Login items y LaunchAgents rotos | **Sí** |
| Simuladores no disponibles | **Sí** (los disponibles no) |
| Cachés de Electron | **Sí** |
| Cachés de rutas fijas (Telegram, WeChat, QQ, Youku, Adobe, migración) | No |
| Caché de Photos Desktop (salvo el archivo más reciente) | **Sí** |
| Caché de CoreSimulator, DMG de usuarios eliminados | No |
| DerivedData (excepto ModuleCache/SymbolCache) | **Sí** |
| ModuleCache.noindex, SymbolCache.noindex, Archives, DeviceSupport, Module caches, DocumentationCache, Runtimes | No |
| iOS Device Logs | **Sí** |
