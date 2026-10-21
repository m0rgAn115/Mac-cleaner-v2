# 12 · Especificación funcional: detalles restantes de limpieza

Completa 08–10 con lo que quedaba pendiente de las funciones de limpieza de
CleanMyMac 5.5.3. Etiquetas: **[O]** observado · **[I]** inferido ·
**[?]** desconocido.

| Bloque | Target | Evidence |
|:--|:--|:--|
| Electron y rutas fijas de cachés | `thin/SystemJunkScanning` | `ev_76e6560a…`, `ev_9f1d92f0…`; literales `CFString` decodificados del binario |
| Simuladores, login items, agentes, usuarios eliminados, caché de CoreSimulator | `thin/SystemJunkScanning` | `ev_ab805002…`, `ev_e9be0cff…` |
| Logs privados (listas constantes) | `thin/SystemJunkScanning` | `NSConstantArray` en `0x65ba8` y `0x65bc0` |
| Versiones de documentos | `thin/SystemJunkScanning` | `ev_0d1bb2a8…`, `ev_b108a608…` |
| Spotlight y filtro de Dropbox | `thin/SharedObjcUtils` | `ev_9155d0b0…`, `ev_47945f2f…` |
| Mail | `thin/MailJunkScanning` (`3946affe…`), `thin/MailboxService` | `ev_27a4d16f…`, `ev_66282f48…`, `ev_714a88c3…` |
| Recursos de una app (desinstalador y leftovers) | `thin/UninstallerScanning`, `thin/SharedObjcUtils` | `ev_674e3ac4…`, `ev_6503bb28…`, `ev_ba598b0d…` |

---

## 1. Cachés de apps Electron **[O]**

1. Recorre las **apps del usuario** (`systemInfo.userApplications`) y se queda
   con las que son Electron (`isElectronApplication`).
2. URL de caché:
   - app no sandboxed → `~/Library/Application Support/<NombreApp>/Cache`
   - app sandboxed → `<contenedor>/Library/Application Support/<NombreApp>/Cache`
3. Solo si existe y no está en la denylist.
4. Un grupo por bundle ID con un único ítem (la carpeta `Cache` entera).
   **`autoselected = YES`**.

## 2. Cachés de rutas fijas **[O]**

| Grupo (identificador) | Ruta | Qué se marca | Preselección |
|:--|:--|:--|:--|
| `ru.keepcoder.Telegram` | `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram` | en el nivel 2 de profundidad, cada carpeta `account-*` → `<account>/postbox/media` | NO |
| `org.telegram.desktop` | `~/Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data` | `cache` y `media_cache` | NO |
| `com.tdesktop.Telegram` | `~/Library/Application Support/Telegram Desktop/tdata/user_data` | `cache` y `media_cache` | NO |
| `com.tencent.xinWeChat` | `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9` | por cada subcarpeta (sin ocultos) → `<sub>/Message/MessageTemp` si existe | NO |
| `com.tencent.tenvideo` | `~/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video` | la carpeta | NO |
| `com.tencent.QQMusicMac` | `~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic` | la carpeta | NO |
| `com.youku.mac` | `~/Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE` | la carpeta | NO |
| `Adobe Premier Pro Media Cache` | `~/Library/Application Support/Adobe/Common/Media Cache Files` | la carpeta | NO |
| `System Migration Cache` | primera entrada de `/Library/SystemMigration/History` cuyo nombre empieza por `Migration-` → `/Library/SystemMigration/History/<entrada>/QuarantineRoot/private/var/db/dyld` | la carpeta | NO |
| `com.apple.Photos` | `~/Library/Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0` | **todos los archivos salvo el accedido más recientemente** (`lastAccessDate`) | **SÍ** |

Para cada ruta se exige que exista, que no esté restringida
(`isFileRestricted`) y que no esté en la denylist.

## 3. Logs privados — listas exactas **[O]**

- **Nombres exactos** dentro de `/private/var/log`: `DiagnosticMessages`, `cups`,
  `daily.out`, `weekly.out`, `monthly.out`, `system.log`, `install.log`,
  `wifi.log`, `sck_hfs.log`, `fsck_hfs.log`, `fsck_apfs.log`.
- **Patrones regex** sobre el nombre de cada hijo de `/private/var/log`:
  `system.log.\d.gz`, `wifi.log.\d.bz2`.
- Filtros y preselección según 08 §3.3 (> 10 KB, preseleccionados).

## 4. Xcode y sistema: preselección que faltaba **[O]**

| Categoría | Regla |
|:--|:--|
| Simuladores | Lista de `xcrun simctl list devices -j`. Agrupados por runtime; los que no pertenecen a un runtime válido van a un grupo “unused”. Ruta: `~/Library/Developer/CoreSimulator/Devices/<udid>`. **Preseleccionado si `isAvailable == false`** (o `availability ≠ "(available)"` en versiones antiguas); los disponibles no |
| Caché de CoreSimulator | `~/Library/Developer/CoreSimulator/Caches`, un ítem; **NO** preseleccionado |
| Usuarios eliminados | En `/Users/Deleted Users`, **solo archivos `.dmg`** (los que crea macOS al borrar un usuario); **NO** preseleccionados |
| Login items rotos | De `loginItemsManager.loginItemInfos`: roto si no tiene URL (solo nombre) o si la URL no existe. **SÍ** preseleccionado |
| LaunchAgents/Daemons rotos | De `systemInfo.allLaunchFiles`: plist legible, no ignorado y roto según 08 §5. **SÍ** preseleccionado |

## 5. Versiones de documentos **[O]**

1. Spotlight (ámbito Home, 09 §2) por los tipos de archivo de la especificación
   (iWork y otros), excluyendo Dropbox.
2. Agrupa por app (bundle ID); la denylist puede ignorar una app entera.
3. Por cada documento obtiene sus versiones guardadas (`.DocumentRevisions-V100`
   [I]) y las ordena por fecha de modificación **de la más nueva a la más
   antigua**.
4. **Regla de preselección** (`CMDocumentVersionsSelectionRule`):
   - la versión más reciente (índice 0) y la más antigua (último índice)
     **nunca** se preseleccionan;
   - una versión intermedia se preselecciona si su fecha está a **menos de
     4 horas (14 400 s)** de la versión anterior de la lista (la más nueva
     siguiente).
5. Las versiones de tamaño 0 se descartan; los documentos y apps sin
   versiones también. Las apps del grupo: `autoselected = NO`; la
   preselección es por versión.

## 6. Búsqueda Spotlight y filtro de Dropbox **[O]**

- `CMMetadataSearchQueryFactory.factory` = `MDQuery` con ámbito
  **`NSMetadataQueryUserHomeScope`** (solo Home) y orden por `kMDItemFSSize`.
  La consulta filtra por tipo de contenido.
- Afecta a: **DMG sin uso** (09 §2) y **versiones de documentos**.
- `CMDropboxFilter`: excluye cualquier ruta que **empiece por** la ruta raíz de
  una cuenta de Dropbox (`dropbox.fetchAccounts`).

## 7. Mail **[O]**

### 7.1 Adjuntos guardados en buzones
- Fuente: `CMMailInfo.mailboxes` (`MailboxService`; lee la base de Mail, literal
  `SELECT count(*) FROM attachments`, y `~/Library/Mail/V*/…`).
- Solo buzones `availableForClean`: **no offline, habilitados y de tipo
  `IMAPAccount` o `AosImapAccount` (iCloud)**, es decir, cuentas en las que el
  servidor conserva el original. Las cuentas POP/Exchange/locales se excluyen.
- Dentro de la carpeta del buzón se recorren (sin ocultos) las carpetas
  llamadas `attachments` (sin distinguir mayúsculas); cada archivo o paquete
  dentro es un adjunto; los directorios normales se recorren.
- Cada adjunto: excluido si su ruta está en la denylist (`isPathIgnored`) o si
  el adjunto lo está (`isAttachmentIgnored`).
- **Agrupa las copias** de un mismo adjunto con la clave
  `<nombre de archivo>` + `<tamaño en bytes>`: un grupo por clave con todas las
  copias.
- **`autoselected = YES`** para grupos y archivos.

### 7.2 “Mail Downloads”
- Raíces: `~/Library/Mail Downloads/` y
  `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/`
  (literales de `MailboxService`). Recorrido sin ocultos.
- Se ignora `.DS_Store`.
- Si una entrada es una carpeta con nombre tipo UUID (regex
  `\w{8}-\w{4}-…-\w{12}`), se toma **su último hijo** como el archivo real.
- **Preselección: YES si `fecha de creación == fecha de modificación`**, es
  decir, si el archivo no se modificó tras descargarse; si no, NO.

## 8. Recursos de una app (base del desinstalador y de los leftovers) **[O]**

### 8.1 Fetchers que se ejecutan, en orden
`SupportingFiles`, `PreferencesFiles`, `LaunchDemons`, `CrashLogs`, `Cookies`,
`LoginItems`, `Logs`, `ApplicationSavedState`, `LibraryPaths`, `PDFServices`,
`Plugins`, `ApplicationHelp`, `ExtraFilesForSandboxedApplication`, `TempFiles`,
`ApplicationContainer`, `Receipt`, `ResourcesFromKnowledgeBase`, `DockIcon`,
`Caches` y, **solo con Full Disk Access**, `DownloadFiles`.

### 8.2 Regla de coincidencia de nombres
- `libraryPaths` = `[~/Library, /Library]` y `applicationSupportPaths` =
  `[~/Library/Application Support, /Library/Application Support]`.
- `LibraryPaths`: en cada raíz busca entradas cuyo nombre sea:
  1. **exactamente el bundle ID** (si difiere del nombre de la app), o
  2. **coincidente por palabras** con el nombre de la app.
- **Profundidad: solo los hijos directos** de cada raíz (`fts_open` con
  `FTS_PHYSICAL|FTS_NOSTAT|FTS_NOCHDIR` y `FTS_SKIP` en cada entrada).
- A los **archivos** se les quita la extensión antes de comparar; a los
  directorios no.
- Coincidencia por **bundle ID**: el nombre en minúsculas **contiene** el
  bundle ID como subcadena (p. ej. `com.foo.bar.plist`, `group.com.foo.bar`).
- **Coincidencia por palabras**: en minúsculas, partir el nombre del recurso
  y el nombre de la app por separadores; es válido si **todas las palabras de
  la app** están en el recurso. **Se rechaza** si el recurso empieza por el
  nombre de la app y lo que sigue contiene la regex **`\s*\d+`** (otra versión
  de la app, p. ej. `Foo 2` frente a la app `Foo`). En la coincidencia por
  palabras, el nombre del archivo se parte por espacios.
- `PreferencesFiles`: sobre todas las preferencias conocidas
  (`systemInfo.allPreferencesNames`), válido si coincide por palabras con el
  **bundle ID usando `.` como separador**, o con el nombre de la app usando un
  conjunto de separadores; además debe existir.
- `ApplicationContainer`: el `sandboxContainerPath` de la app.
- Todos descartan lo que la denylist marca como sistema o ignorado
  (`isIgnoreOrSystemItemFileWithPath`).

### 8.3 Leftovers
Los candidatos (07 #12) pasan por estos mismos fetchers para reunir sus
archivos.

### 8.4 Atributos de cada recurso **[O]**
`CMApplicationResource{value, bundleIdentifier, type, isRemovable, size,
isInsideContainer, isInsideRootContainer}`:
- `isInsideContainer` = la ruta empieza por `~/Library/Containers` (salvo el
  tipo `0x20000`);
- `isInsideRootContainer` = es el contenedor completo (hijo directo de
  `~/Library/Containers`);
- tipos observados: `1` = preferencias, `0x10` = rutas de `~/Library`.
- El escaneo **no asigna preselección** a los recursos: eso lo decide la capa
  de interfaz del módulo de Aplicaciones (fuera de los frameworks de escaneo).
