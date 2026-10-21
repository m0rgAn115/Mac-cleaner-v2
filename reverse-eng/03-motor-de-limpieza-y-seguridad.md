# 03 · Motor de limpieza y seguridad

Fuente: `symbols/CleaningCore.txt` (`ev_356667e1…`), `NodesCore.txt`
(`ev_493306cb…`), `ScanningCore.txt` (`ev_8c1fcb0a…`), `FileManagerService.txt`
(`ev_f1d21a13…`), `PrivilegedOperationsPerformerService.txt` (`ev_ff07c55b…`),
`PrivilegedRoutines.txt` (`ev_5fe33c49…`), `ApplicationsTerminator.txt`
(`ev_a9003cad…`).

## 1. Escaneo: cola de tareas con dependencias (`ScanningCore`)

Observado:

- `ProcessingQueue` + `ProcessingQueueDependenciesResolver` +
  `DependentTask` / `ApplicationDependency` → las tareas declaran dependencias
  (p. ej. “la app X debe estar cerrada”).
- `TaskWatcher` con `TimeoutProblem`, `StaleProblem`, `TimeoutAction`,
  `ProblematicTaskInfo` → **cada tarea tiene vigilancia de timeout/estancamiento**
  y se reporta en vez de colgar el escaneo completo.
- `TaskPriorityKind`, `PrioritizableTask`.
- Progreso compuesto: `CompoundProgress`, `CountableProgress`,
  `PercentagesProgress`, `ScanProgress`.
- `Controllable` / `ControlObject` / `AsyncControlObject` → pausa, reanuda y
  cancela de forma uniforme.

## 2. Resultados: árbol de nodos con propiedades (`NodesCore`)

Observado:

- `Node{identifier,name,parent,children,nodeProperties}` con mutaciones
  observables (`onChildAdded`, `onChildRemoved`, `NodeChildrenMutationContext`).
- **Propiedades enchufables** (`NodePropertyType` con `onAttach`,
  `onChildrenAdded`, `beginChildrenMutation`…):
  - `Selection` → estado tri-estado, `totalSelectedLeafChildrenCount`,
    `selectionSnapshot()`.
  - `SelectableSizer` / `SimpleSizer` → tamaño agregado de lo seleccionado,
    recalculado incrementalmente.
  - `IgnoreInfo` → `canBeIgnored`, `ignore(node:)` (“no volver a mostrar”).
  - `FeaturedNode` → features arbitrarias tipadas.
- `NodeView` con `Projection{filter,sort,searchFilter}` → vistas
  ordenadas/filtradas sin copiar el árbol.
- `NodesReferencesRegistry` y `NodesSnapshotsStorage(makeSnapshot/restore)` →
  el mismo archivo puede aparecer en varios grupos (referencias) y la
  selección se puede guardar/restaurar.
- `GroupedInfoContainer{title, groupDescription, shouldAppearInDataManager}`.

## 3. Limpieza (`CleaningCore`)

Observado:

- Un nodo es `CleanableNodeType` si tiene `withCleaner(id:name:selector:operation:)`:
  el limpiador se adjunta al nodo del árbol. `RootNodeCleaner` recorre y
  `OperationBasedNodeCleaner(info:selector:filter:operation:)` ejecuta.
- `TasksProcessor` (pausa/reanuda/cancela, publishers de progreso y título);
  `MinimumTotalDurationTasksProcessor` / `MinimumValueDurationTasksProcessor`
  → **inferido**: duración mínima artificial para que la UI no “parpadee”.
- `CleanQueueResult{items, outcome.hasFailedResults}`,
  `CleanTaskOperationResult`, `FileRemovalTaskError{path, underlyingError}`
  → resultado por ítem, fallos parciales explícitos.
- `CleanQueueResultNodesUpdater(cascadeRemovalFilter:)` → tras limpiar,
  actualiza el árbol quitando los nodos borrados y sus padres vacíos.
- `CleanupAwareNode{willUpdateAfterCleanup, didUpdateAfterCleanup}`.
- **Removers intercambiables** (todos con `remove(at:)`):
  - `FileRemover` — borrado directo.
  - `MoveToTrashFileRemover` — a la Papelera.
  - `PrivilegedFileRemover(remover:privilegedAgent:authorizeAgentBlock:)` —
    escala a root sólo si hace falta, error `NotAuthorizedPrivilegedAgentError`.
  - `DebugFileRemover` + `ConfigDependentFileRemover(debugRemover:realRemover:)`
    y `Config.isDebugRemovalEnabled` / `isDebugFailCleanEnabled` /
    `DebugFailCleanError` → **modo simulación** y **inyección de fallos** para
    probar la UI de errores sin borrar nada.
- `FilesRemovalTask(dependenciesFetcher:throwErrorIfDependenciesUnresolved:)`
  → no borra si una dependencia (p. ej. app cerrada) no se cumplió;
  `DependencyNotFulfilledForNodeError`.

## 4. Cerrar apps antes de limpiar (`ApplicationsTerminator`)

Observado: `TerminatorViewModel(bundleIDs:…)` con `terminateAll()`,
`ignore()`, `onAllApplicationsTerminated`. **Inferido**: si una categoría
depende de una app en ejecución (cache de Chrome, Mail…), se muestra un
diálogo “cierra estas apps” y la tarea queda pendiente hasta que se cierran
o el usuario las ignora.

## 5. Operaciones de archivo (`FileManagerService`)

Observado, relevante para seguridad:

- `isFileProtectedByRootless(atPath:)` → comprueba **SIP** antes de intentar.
- `isFileRestricted`, `isDeletableFile`, `isWritableFile`.
- `removeFileAndHandleLock(atPath:)` → gestiona el flag *locked* (`uchg`).
- `actualFolderTargetURL(_:)` → resuelve alias/symlinks antes de operar.
- `isUbiquitousItem`, `evictUbiquitousItem`, `iCloudAliasPath` → distingue
  archivos de iCloud no descargados.
- `lastAccessDate(atPath:)` → criterio de antigüedad por último acceso.
- `FileSizingService.byteSize(atURL:cancellationFlag:)` y `logicalSize` →
  distingue tamaño físico vs lógico (sparse/clones APFS) y es cancelable.
- `realHomeDirectory` (vs home del contenedor sandbox).
- `VolumeInfoManager` (interno/externo, solo-lectura, expulsable).

## 6. Privilegios

Observado:

- `PrivilegedOperationsPerformerService` agrupa clientes por dominio:
  FileSystem, Logs, Lipo, Launchd, BrokenStartupItems, PackageReceipt,
  MaintenanceTask, HealthCheck, UserAuthorization, PantherEngine.
- `PrivilegedRoutines` (Objective-C, prefijo `PAN`): tareas atómicas por
  identificador — enumerar, tamaño, borrar archivo, terminar proceso,
  borrar/consultar cron jobs, launch agents, perfiles de configuración,
  resetear homepage de Safari, team identifier/bundle ID de un binario.
- `deauthorizePrivilegedAgent(shouldUninstall:)` → el agente se puede revocar.

**Inferido**: el agente root sólo expone operaciones **enumeradas**, nunca un
“ejecuta este comando” genérico.

## 7. Persistencia

`DatabaseKit.DatabaseDriver` sobre FMDB/SQLite con migraciones y
`passphraseCorrupted` → base local cifrada (historial/estadísticas/ignorados:
*desconocido* qué guarda exactamente).

## Lo que este diseño hace bien y conviene copiar como idea

1. **Reglas como datos** separadas del motor.
2. **Autoselección por ítem** en lugar de por categoría.
3. **Ignorar persistente** a nivel de nodo.
4. **Dependencias de tarea** (app cerrada) y timeouts por tarea.
5. **Remover inyectable** con modo simulación y fallos inducidos para tests.
6. **Resultado por ítem** con fallos parciales y actualización en cascada del árbol.
7. **Comprobaciones previas**: SIP, locked, iCloud no descargado, symlink/alias.
