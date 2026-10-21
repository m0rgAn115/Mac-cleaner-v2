# 09 · Especificación funcional: Papeleras, imágenes de disco y Descargas

Comportamiento de CleanMyMac 5.5.3, descrito para poder implementarlo sin
volver a analizar el binario. Mismas etiquetas que en 08: **[O]** observado ·
**[I]** inferido · **[?]** desconocido.

| Bloque | Target (slice arm64) | Evidence |
|:--|:--|:--|
| Papeleras | `thin/TrashJunkScanning` `7e49483c…` | `ev_afbbb90d…` |
| Imágenes de disco | `thin/UnusedDiskImagesScanning` `4bb98eec…` | `ev_1bb9eeeb…` |
| Descargas | `thin/DownloadsScanning` `e41cb726…` | `ev_3d49509b…`, `ev_1f724a78…`; constante leída del `__TEXT,__const` |

---

## 1. Papeleras

### 1.1 Papelera del sistema + iCloud **[O]**
1. Raíces = `iCloudTrashes` + `systemTrash` (`~/.Trash`). Literales de
   `iCloudTrashes` en `SharedObjcUtils` **[O]**:
   `~/Library/Mobile Documents/com~apple~CloudDocs/.Trash`,
   `~/Library/CloudStorage/iCloud Drive/.Trash`,
   `~/Library/Mobile Documents/.Trash`.
2. Si `includeICloudTrashes = YES`, se añaden las papeleras de cada contenedor
   de iCloud Drive: para cada hijo de `~/Library/Mobile Documents/`, la ruta
   `<hijo>/Documents/.Trash` si existe.
3. Por cada raíz: **hijos directos sin ocultos** (opción “skip hidden”).
4. Resultado: un único grupo, **`autoselected = YES`**, con todos esos hijos.
5. Los ítems que vienen de raíces de iCloud se marcan como archivo en la nube
   (`TrashFileModel.isCloudFile`) **[I]** (se pasa la lista de raíces de iCloud
   al iterador).
6. `TrashFileModel.isApplicationFromAppStore` existe **[O]**; **[?]** uso.

### 1.2 Papeleras de volúmenes montados **[O]**
1. Se listan los volúmenes montados (sin ocultos), pidiendo
   `IsBrowsable`, `IsInternal`, `IsLocal`, `IsReadOnly`.
2. Un volumen es **limpiable** solo si:
   - su ruta contiene `/Volumes/`;
   - es *browsable*;
   - es **local**;
   - **no** es de solo lectura.
3. Para cada volumen limpiable: `<volumen>/.Trashes/<uid>`; se listan sus
   hijos directos y se agrupan bajo el volumen.
4. **`autoselected = YES`**.

### 1.3 Papelera de Mail **[O]**
Solo si el buzón está habilitado (`mailbox.isEnabled`). `CMMailBox.trashes`:
dentro del buzón de papelera (`trashMailBoxURL`) recorre (sin ocultos) las
carpetas llamadas `data` y toma cada archivo o paquete que contienen. El iterador solo acepta archivos con extensión **`.emlx` o `.emlxpart`**
(mensajes borrados). Agrupa por buzón.
(Los adjuntos de Mail fuera de la papelera se tratan en 12 §7.)

---

## 2. Imágenes de disco “sin uso” **[O]**

> ⚠️ **Corrige el reporte 02.** CleanMyMac **no** comprueba si la app del DMG
> ya está instalada.

1. Búsqueda con **Spotlight** (`CMMetadataSearchController`) de archivos de
   tipo **`com.apple.disk-image-udif`**, **solo en la carpeta Home**
   (`NSMetadataQueryUserHomeScope`) y ordenados por tamaño (12 §6).
2. Exclusiones:
   - `kb.shouldIgnoreURL(url)` (denylist);
   - `CMDropboxFilter.isItemFilteredAtPath` → excluye lo que está dentro de
     carpetas de Dropbox.
3. Tamaño = `kMDItemPhysicalSize` de Spotlight; si no está, tamaño calculado.
4. **`autoselected = NO`** para todos.

En la práctica la categoría es una lista de **todos los DMG que Spotlight
conoce**, con nada preseleccionado.

---

## 3. Descargas por origen **[O]**

Constante del binario: `kMoreThanMonthAgo = 30` (entero, días). En el código se
usa como intervalo `-2 592 000 s` (`NSDate().addingTimeInterval(-30 días)`).

### 3.1 Estructura
`Aplicación (Safari/Chrome/Slack) → Cuenta/perfil → Archivo`. Cada nivel pasa por
la denylist (`shouldIgnoreApplication`, `shouldIgnoreAccount:ofApplication:`,
`shouldIgnoreURL`). Los archivos de tamaño 0 se descartan.

### 3.2 Safari
- Fuente: historial de descargas de Safari (`dataController.fetchDownloadsHistory`),
  deduplicado (`_compareAndRemoveDuplicate:`). Una única cuenta `default`.
- Por entrada:
  - si la descarga está **incompleta** (`bytesSoFar ≠ totalToLoad`), el ítem es
    la **carpeta contenedora** de la ruta (la descarga parcial `.download`) **[I]**;
  - solo si el archivo existe y no está en la denylist.
- **Preselección:** **YES** solo si la descarga está **incompleta y Safari no
  se está ejecutando** (comprueba `NSWorkspace.runningApplications` por bundle
  ID). Las descargas completas → **NO**.

### 3.3 Chrome
- Fuente: base de datos de historial de Chrome por perfil (claves
  `CMChromeDownloadItemKey*`), con cuentas desde el JSON de perfiles.
  `CMChromeDownloadItem.fullyDownloaded` existe.
- Por entrada: si existe y no está en la denylist → ítem.
- **Preselección: siempre NO.**

### 3.4 Slack
- Fuente: el storage de Slack
  (`~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/storage`),
  agrupado por equipo (`teamId`, `teamName`).
- Se **excluyen** las descargas con estado `progressing` o en pausa.
- **Preselección:**
  - **YES** si `downloadStartTime ≠ 0` **y** empezó hace **más de 30 días**;
  - además, si `downloadProgress < 1`: **YES** si el estado es `completed` o
    `interrupted` (descarga rota o incompleta).

### 3.5 Resumen
| Origen | Preseleccionado |
|:--|:--|
| Safari, descarga incompleta y Safari cerrado | Sí |
| Safari, descarga completa | No |
| Chrome | No |
| Slack, más de 30 días | Sí |
| Slack, incompleta (`completed` o `interrupted` con progreso < 1) | Sí |
| Slack, en curso o en pausa | Excluida |
