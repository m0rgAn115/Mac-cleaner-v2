# 10 · Especificación funcional: cómo ejecuta CleanMyMac la limpieza

Complementa al reporte 03 (arquitectura) con lo **observado en la
decompilación** sobre cómo se borra lo seleccionado. Etiquetas: **[O]**
observado · **[I]** inferido · **[?]** desconocido.

| Fuente | Evidence |
|:--|:--|
| Strings de `thin/JunkCleanupModule` (`08bd534c…`) | `ev_1e273ed6…` |
| Dependencias “app en ejecución” (`ModuleCore`) | `ev_d2a183d7…` (ver 07 #11) |
| Removers de `CleaningCore` | `symbols/CleaningCore.txt` (`ev_356667e1…`) |
| Búsqueda de usos de “mover a la Papelera” en todos los binarios | `strings`/símbolos de los 120 frameworks + ejecutable + login items |

---

## 1. Borrado definitivo, no Papelera **[O]**

- `JunkCleanupModule` (que limpia System Junk y las papeleras) solo referencia
  estos removers de `CleaningCore`: **`FileRemover`** (borrado directo),
  **`PrivilegedFileRemover`** y **`ConfigDependentFileRemover`**.
- **`MoveToTrashFileRemover` existe en `CleaningCore`, pero ningún otro binario
  de la app lo referencia** (búsqueda en todos los frameworks, el ejecutable y
  los login items).
- Conclusión **[O por ausencia de referencias]**: la limpieza de basura de
  CleanMyMac **borra de forma definitiva**; no mueve a la Papelera.

## 2. Escalado de privilegios **[O símbolos]**

- `PrivilegedFileRemover(remover:privilegedAgent:authorizeAgentBlock:)` envuelve
  al remover normal. **[I]** Intenta borrar como usuario y, si no tiene
  permiso, pide autorización al agente root; si no se autoriza, falla con
  `NotAuthorizedPrivilegedAgentError(path)`.
- Removers específicos que usan el agente: `LogsRemover`,
  `BrokenStartupItemRemover`; también `systemCache` y `systemLogs` reciben
  `privilegedOperationsPerformer` en el escaneo.

## 3. Modo simulación y modo de fallo forzado **[O]**

Cada remover específico tiene una versión `ConfigDependent…` que elige entre el
real y uno de *debug* según la configuración:

| Real | Debug |
|:--|:--|
| `BrokenPreferencesRemover` | `DebugBrokenPreferencesRemover` |
| `BrokenStartupItemRemover` | `DebugBrokenStartupItemRemover` |
| `FileVersionRemover` | `DebugFileVersionRemover` |
| `LogsRemover` | `DebugLogsRemover` |
| `XcodeSimulatorRemover` | `DebugXcodeSimulatorRemover` |
| `FileRemover` | `DebugFileRemover` |

- Constructor común: `(throwIfFailCleanEnabled, debugRemover, realRemover, removeAction)`.
- El remover de debug **solo registra** (literal `"[SIMULATE]: log removal at "`).
- `Config.isDebugFailCleanEnabled` → lanza `DebugFailCleanError` para probar la
  UI de errores.
- Hooks `onRemoveSucceed` / `onRemoveFailed(error)` en todos los removers.

## 4. Orden y control de la ejecución **[O]**

1. **Antes**: `ResolveDependenciesTask` comprueba las apps en ejecución por
   bundle ID y muestra la ventana para cerrarlas (07 #11).
2. **Tareas**: `FilesRemovalTask(value, fileRemover, urlResolver,
   dependenciesFetcher, throwErrorIfDependenciesUnresolved)`; si la dependencia
   no se cumple, la tarea falla en lugar de borrar.
3. **Después**: `FinalizeDependenciesTask` reabre en segundo plano las apps que
   cerró, si está activado `relaunchApplicationsOnFinalize`.
4. Se puede pausar, reanudar y cancelar (`TasksProcessor`).
5. Resultado por ítem (`CleanQueueResult` con `hasFailedResults`). El árbol se
   actualiza en cascada quitando lo borrado (`CleanQueueResultNodesUpdater`).
6. Errores con *handlers* por tipo:
   `BrokenPreferencesRemovalTaskErrorHandler`,
   `BrokenLoginItemsRemovalTaskErrorHandler`,
   `DocumentVersionRemovalTaskErrorHandler`,
   `UniversalBinaryRemovalTaskErrorHandler`.

## 5. Casos especiales de borrado **[O símbolos / I]**

| Categoría | Cómo se borra |
|:--|:--|
| Simuladores / runtimes | `simctl` por UUID (`XcodeSimulatorRemover`, `XcodeSimulatorRuntimeRemover`), no borrando carpetas |
| Preferencias rotas | `BrokenPreferencesRemover(fileManager, prefsdManager: CMCFPrefsdManager)`; [I] se coordina con `cfprefsd` |
| Login items / LaunchAgents rotos | `BrokenStartupItemRemover(performerService)` con un `brokenLoginItemRemover`; [I] descarga el agente (`launchctl`) antes de borrar el plist |
| Logs | `LogsRemover` con agente privilegiado para `/Library/Logs`, `/private/var/log`… |
| Versiones de documentos | `FileVersionRemover` (API de versiones) |
| Archivos bloqueados (`uchg`) | `removeFileAndHandleLock` — [I] quita el flag antes de borrar (ver 07 #14) |

## 6. Para quien implemente (notas de diseño, no de CleanMyMac)

CleanMyMac borra definitivamente porque su contenido es regenerable y, para la
mayoría de categorías, lo preselecciona sin filtro de edad. Si una
implementación propia quiere ser más conservadora, las palancas que la
decompilación deja claras son:

1. borrar de forma definitiva solo lo que CleanMyMac preselecciona **y** sea
   regenerable; el resto, a la Papelera;
2. añadir un filtro de edad que CleanMyMac no tiene;
3. no escalar privilegios automáticamente;
4. no quitar los flags de bloqueo.
