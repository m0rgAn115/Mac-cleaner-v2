# 07 · Decompilación con Ghidra (sesión 3)

Proveedor: **Ghidra 12.1.4** vía MCP de REA, sobre slices arm64 en `thin/`
(`lipo -thin arm64`). El pseudocódigo es salida del decompilador, no el código
fuente original. Aquí solo se describe el **comportamiento**, sin copiar código.

| Target (slice arm64) | SHA-256 |
|:--|:--|
| `thin/SystemJunkScanning` | `b2b4d2852222a16aee23461f3976b538d746ef7e9af6896384fbad6cf10fce29` |
| `thin/ScanningCore` | `2f84eda8b12c81cc63f4348b95914429f8fe1fe36e6a998b04fde63fa20bd5dd` |
| `thin/ModuleCore` | `f42f43580aff367a6ec6757954b6d73353cb13b0ec90e76eb2c8ee85e45ece33` |
| `thin/UninstallerScanning` | `0f2f38b381e5590180ff0dba03cbff84b0fe30300dae47ba507adc915ccfbef0` |
| `thin/FileManagerService` | `be16cdbdba8d8e26eff2a9034e29618b13c1d8b0c6064a8f3828cf1c0ff79e0f` |
| `thin/SharedObjcUtils` | `7bf05e73b9d5f7a2b7898960424eebcb3b4ef0d36f63aba186d3823ccd657d9d` |

---

## #10 · Caches de contenedores sandboxed — ✅ resuelta

Evidence: `ev_9851129d2720a88232b342eb8c0779f798fbce15d9ec6a3de3d769fd5fa8a4fc`
(batch de 6 funciones), `ev_665655d0e8b343b5897c19a0e9ae7d198f7cca0e18bdb7710167cd888926d0d8`
(bloque por ítem + búsqueda profunda).

### Algoritmo observado

1. **Raíz**: `CMSandboxContainersCachesScanTask` usa `CMPaths.sandboxContainer`
   como directorio (inferido: `~/Library/Containers`) — `0x94d0`.
2. **Enumeración** (`contentOfCachesDirectoryURL`, `0x9588`): lista los hijos
   directos de la raíz (cada contenedor), y para **cada uno** añade la ruta
   relativa literal `Data/Library/Caches` y lista **sus hijos directos**. El
   resultado es la unión plana de `~/Library/Containers/*/Data/Library/Caches/*`.
   Si el directorio no existe o no se puede leer, el contenedor se salta sin
   error. Respeta cancelación entre contenedores.
   **No toca nada más del contenedor** (ni `Data/Documents`, ni
   `Application Support`, ni preferencias).
3. **Filtro** (`CMCacheScanTask::scan`, `0x63c0`): predicado OR de
   `CMFileNamePredicate.dsStoreFileNamePredicate` (ignora `.DS_Store`) y
   `CMFileIgnorePredicate(knowledgeBase)` (lista de exclusión del KB).
4. **Por ítem** (`FUN_00006694`):
   - pausa/cancelación cooperativa (`sleepThreadWhilePaused`, `isCancelled`);
   - si el filtro lo ignora → fuera;
   - si `knowledgeBase.shouldPerformDeepSearchForItem(<nombre>)` → baja **un
     nivel** (`_performDeepSearchForURL`, `0x68c4`): cada hijo es un ítem
     propio dentro de un grupo; el grupo se descarta si queda vacío;
   - si no, calcula el tamaño de toda la carpeta (`_fileSizeAtURL:cancellationFlag:`);
   - **descarta ítems de tamaño 0** salvo que el agente privilegiado esté
     autorizado (inferido: tamaño 0 = no se pudo leer);
   - crea `CMFileModel(url, size, autoselected: isResultAutoselectable)`.
5. **Autoselección**: `CMCacheScanTask.isResultAutoselectable` devuelve
   **siempre `YES`** (`0x6dd0`); `CMGradleCacheScanTask` lo sobrescribe a
   **`NO`** (`0xb058`).

### Lo que NO hace (observado en estas funciones)

- **Ningún filtro por antigüedad**: ni fecha de modificación ni de acceso. Todas
  las caches (salvo Gradle) se preseleccionan sea cual sea su edad.
- Ninguna comprobación de “app en ejecución” en el escaneo; eso pertenece a la
  fase de limpieza (ver #11).

---

## #11 · “Cierra la app primero” — ✅ resuelta (mecanismo); ⚠️ UI de espera inferida

Evidence: `ev_d2a183d71c61f84b80149350103f8bd05e74b94c702afbb67509722da5d111c8`
(ModuleCore), búsqueda `ev_6ef53784ec79c3a9734e5519e77e73812abdfefaf55a515b615965402d3fa27e`,
strings ScanningCore `ev_92241cdbc23968b3bed214950b5e34e43781f75895e980d5ff2e820a2d6283e9`.

### Piezas (observado)

| Capa | Pieza | Rol |
|:--|:--|:--|
| ScanningCore | `ApplicationDependency{bundleID, expectation: String, isFulfilled, fulfill()}` | Una tarea de limpieza declara “necesito que la app X no esté corriendo” |
| ScanningCore | `ProcessingQueueDependenciesResolver` | Mete `ResolveDependenciesTask` **antes** y `FinalizeDependenciesTask` **después** de las tareas de la cola |
| ScanningCore | `DependentTask(throwErrorIfDependenciesUnresolved)` + `UnresolvedDependenciesDependentTaskErrorMapper` | Si la dependencia no se cumplió, la tarea **falla con error** en vez de borrar (`error_description_application_dependency_not_fulfilled`) |
| CleaningCore | `FilesRemovalTask(dependenciesFetcher:throwErrorIfDependenciesUnresolved:)` | El borrado de archivos usa ese mecanismo |
| ModuleCore | `RunningApplicationsDependenciesResolver` | Implementación concreta con `NSWorkspace` |
| ModuleCore / ApplicationsTerminator | `TerminationWindowPresenter`, `TerminatorViewModel{terminateAll, ignore}` | Ventana “cierra estas apps” |

Mensajes de error por tipo de dependencia (literales de ModuleCore):
`removal_logs`, `removal_login_items`, `removal_document_version`,
`removal_universal_binaries`, `maintenance_task`, `browser_group`, `removal`.

### Algoritmo observado

1. **Detección** (`runningApplications(from:)`, `0xf2560`): junta los
   `bundleID` de todas las `ApplicationDependency`, construye un set y recorre
   las apps en ejecución del `NSWorkspace` inyectado, quedándose con las que
   tienen `bundleIdentifier` **exactamente igual** a uno del set. Las apps sin
   bundle ID se ignoran. **No mira procesos sin bundle, ni archivos abiertos.**
2. **Resolución** (`resolveDependencies`, `0xf0c24`, no decompilada por
   tamaño): por los símbolos, presenta la ventana de terminación y guarda las
   URLs de las apps cerradas (`storeTerminatedAppURLs`, `terminatedAppURLs`).
   *Inferido*: el usuario puede “cerrar todas” o “ignorar”, y en ese caso las
   tareas dependientes fallan con el error de arriba.
3. **Finalización** (`finalizeDependencies`, `0xf1f3c`): si el flag
   `relaunchApplicationsOnFinalize` está activo (`0xf0be8`), **vuelve a abrir
   las apps que cerró**, con `NSWorkspaceOpenConfiguration.activates = NO`, es
   decir en segundo plano y sin robar el foco.

---

## #12 · Criterio de “sobras” (leftovers) — ✅ resuelta

Evidence: `ev_75b48df4135f2afc74fbc65bb5f2fe1399ae89c010f713bda5290acb2edc20f3`
(`fetchLeftovers` + plantillas), `ev_3dd63b445385179dedb3ad2674cf99c2499d5ea6c51886e26faccc9e4f278de3`
(5 auxiliares), `ev_b5f59f65abafa2fc13c81883f7a14fbf786e82eebfc149bd8c5f38bb9d71bd98`
(fuentes y comprobación por nombre), strings `ev_060a764b11d4b6c8006a8e39ccd02354675ea0a133adcad587bfd2de9f378602`.

### Fuentes de candidatos (observado)

Solo **dos** fuentes, no todo `~/Library`:

1. **Contenedores sandboxed** (`userSandboxContainers`, `FUN_0001c018`): para cada
   contenedor obtiene el bundle ID y la ruta de su app. Es candidato si la app
   **no existe** (`fileExistsAtPath:` falso) y su bundle ID no está entre las
   apps instaladas.
2. **Preferencias de usuario** (`userPreferences`, `FUN_0001bb30` + `FUN_0001c3b0`),
   filtradas por una lista estática interna (no decodificada). Para cada archivo:
   - le quita la extensión si no es directorio (`com.foo.bar.plist` → `com.foo.bar`);
   - **exige que el nombre contenga un punto**, es decir, que parezca un bundle ID
     en notación DNS inversa;
   - descarta si el bundle ID está instalado.

### Comprobaciones para descartar falsos positivos (observado, en orden)

1. Bundle ID entre las apps instaladas (set construido en `FUN_0001be48`).
2. `knowledgeBase.bundleIDsForFileURL:` → bundle IDs **asociados**; si alguno
   coincide con una app instalada, se descarta. La comparación (`FUN_0001f22c`)
   **ignora espacios y guiones**.
3. `knowledgeBase.applicationNameFor:` → nombre de app; se comprueba si existe
   `/Applications/<nombre>.app` o `~/Applications/<nombre>.app` (plantillas
   literales). También prueba con el último componente del bundle ID
   (`FUN_0001da6c`).
4. `knowledgeBase.isIgnoreOrSystemItemFileWithPath:` → fuera si es de sistema o
   está ignorado.
5. Al final, `isAppIgnoredWithBundleId:` y deduplicación (`FUN_0001f848`).
   El resultado es una lista de `CMApplicationInfo(bundleID, appName)`: una
   “app fantasma” por bundle ID. Luego el desinstalador le busca recursos con
   los *fetchers* del reporte 06 §4.

---

## #14 · Comprobación SIP — ✅ resuelta

Evidence: wrappers en FileManagerService `ev_bc6f25cb962ea50ec441533fc972cc477c897bef9053b12eca0e24700dea5c28`,
implementación en SharedObjcUtils `ev_cbba733a937077ef0b4a7b0072c614aa4ab91f43c0a1e405ab659f723b5e177f`
(xref del literal `ev_5e9cea40a4802cc8fbd1dc4ec3b29d9bb471ca7d241cc27852478fd6b3b3f222`).

- `FileManagerProvider.isFileProtectedByRootless` / `isFileRestricted` /
  `removeFileAndHandleLock` (Swift) son **wrappers** que reenvían a una
  categoría ObjC de `NSFileManager` en `SharedObjcUtils`.
- `isFileProtectedByRootless:` (`0x265c`): llama a `listxattr(path, …,
  XATTR_NOFOLLOW)` y devuelve `YES` si alguno de los atributos se llama
  **`com.apple.rootless`**. No mira `st_flags`.
- `SharedObjcUtils` importa `stat` y `chflags`. **Inferido**: `isFileRestricted:`
  mira `SF_RESTRICTED` en `st_flags`, y `removeFileAndHandleLock` quita
  `UF_IMMUTABLE` con `chflags` antes de borrar. No se decompiló.

