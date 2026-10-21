# 05 · Checklist de investigación y preguntas abiertas

Estado al 2026-10-15 (sesión 5: specs 08–12; alcance = solo limpieza). Actualiza este archivo en cada sesión.

## Respondidas

| # | Pregunta | Estado | Evidencia |
|:--|:--|:--|:--|
| 1 | ¿Cómo está estructurado el bundle? | ✅ Respondida | `ev_633fec5c…`, `ev_c40ebeee…` |
| 2 | ¿Está sandboxed? ¿Con qué permisos? | ✅ Respondida | `ev_895d9e52…` |
| 3 | ¿Qué categorías de System Junk existen? | ✅ Respondida (a nivel de nombres) | `ev_0e69247b…` |
| 4 | ¿Qué cubren Trash, Mail, Downloads, DMG, Uninstaller, Updater, Privacy, Performance, SpaceLens, Organize, Cloud? | ✅ Respondida (a nivel de nombres) | ver 02 |
| 5 | ¿Cómo modelan los resultados y la selección? | ✅ Respondida | `NodesCore` `ev_493306cb…` |
| 6 | ¿Cómo ejecutan la limpieza y manejan errores? | ✅ Respondida (a nivel de API) | `CleaningCore` `ev_356667e1…` |
| 7 | ¿De dónde salen las reglas? | ✅ Contrato resuelto: el `.cmmkb` responde sobre todo preguntas de **exclusión** (`isIgnoreItem:`, `shouldIgnoreURL:`…); las ubicaciones están en código. El contenido del archivo sigue opaco y fuera de alcance | ver 06, `ev_c8e6a255…`, `ev_6366c56f…` |
| 13 | ¿Qué es `isAggressor`? | ✅ Marca apps de desarrolladores de un “país agresor” (bundle ID o certificado). Es una política del producto: no replicar | 06 §4, `ev_6366c56f…` |
| 10 | ¿Qué contenedores sandboxed limpia? | ✅ Solo `Containers/*/Data/Library/Caches/*`, sin filtro de edad; todo autoseleccionado salvo Gradle | 07 #10 |
| 11 | ¿Cómo detecta apps abiertas? | ✅ `ApplicationDependency` + `RunningApplicationsDependenciesResolver` (NSWorkspace, por bundle ID exacto); relanza en segundo plano al terminar | 07 #11 |
| 12 | ¿Criterio de leftovers? | ✅ Candidatos solo de contenedores sin app y plists de Preferences con forma de bundle ID; 4 filtros anti-falsos-positivos | 07 #12 |
| 14 | ¿Cómo comprueba SIP? | ✅ xattr `com.apple.rootless` (`listxattr`, NOFOLLOW) | 07 #14 |
| 8 | ¿Hay filtro de antigüedad en System Junk? | ✅ No en ninguna categoría decompilada (cachés, logs, Xcode, preferencias, backups). Solo Descargas de Slack usa 30 días | 08 §0.5, 09 §3 |
| 9 | ¿Qué es `kMoreThanMonthAgo`? | ✅ = 30 días; solo Slack lo usa para preseleccionar | 09 §3 |
| 20 | ¿Borra o mueve a la Papelera? | ✅ Borra de forma definitiva: `MoveToTrashFileRemover` no se usa en ningún otro binario | 10 §1 |
| 21 | ¿Qué DMG considera sin uso? | ✅ Todos los UDIF de Spotlight salvo Dropbox y denylist; ninguno preseleccionado | 09 §2 |
| 22 | Detalles de limpieza pendientes (Electron, rutas fijas, simuladores, login items, logs privados, DMG/Spotlight, Mail, versiones, usuarios eliminados, recursos de apps) | ✅ | 12 |
| 23 | Profundidad de búsqueda de restos, regex de versión, cuentas de Mail limpiables, caché de migración | ✅ | 12 §2, §7, §8 |
| 8b | ¿Hay predicado de antigüedad en el núcleo ObjC? | ✅ No: solo existencia, ignorar, alcanzable, nombre y tamaño. La autoselección de caches es `isResultAutoselectable` por tarea | 06 §2, `ev_974afa6b…` |

## Pendientes de decompilación (Ghidra ya instalado: usar slices en `thin/`)

Ver también la tabla de pendientes en 11 §4.

| # | Pregunta | Cómo investigarla | Por qué importa |
|:--|:--|:--|:--|

## Pendientes que pueden hacerse sin motor nativo

| # | Pregunta | Cómo |
|:--|:--|:--|
| 15 | Entitlements de los login items | `rea inspect-signature` sobre cada `.app` de `LoginItems` |
| 16 | Textos de UI por categoría (descripción de riesgo de cada una) | `*.lproj/*.strings` de `JunkCleanupModule` y `SystemJunkScanning`: sirven para inspirarse en cómo explicar cada categoría al usuario (no copiar) |
| 17 | ¿Qué rutas reales toca en ejecución? | Observación de runtime (`rea capture-process` o `fs_usage`) mientras CMM escanea. Requiere aceptar ejecutar la app y sus permisos. **No hecho.** |
| 18 | Comparar versiones futuras | `tools/reproduce.sh` en un directorio nuevo y `diff -r symbols/` |

## Pendientes sin motor nativo (sesión 3)

| # | Pregunta | Cómo |
|:--|:--|:--|
| 19 | Metadatos ObjC del resto de frameworks (`PrivacyScanning`, `MailJunkScanning`, `PerformanceScanning`, `ApplicationsService`, `CleaningCore`) | MCP: `open_binary` + `inspect_native_dispatch_metadata` (max_records 20000) y luego `tools/summarize_dispatch.py` |

## Notas para el próximo agente

- El MCP de REA funciona (verificado en la sesión 2). Las salidas grandes de
  `inspect_native_dispatch_metadata` se guardan en `tool-results/`: cópialas a
  `evidence/20-dispatch-<Framework>.json` y resúmelas con `tools/summarize_dispatch.py`.
- Ghidra: `open_binary` con `provider_id: "ghidra"` sobre `reverse-eng/thin/<Framework>` (no sobre el universal de la app).
- Si no aparece, usa el CLI: `~/.nvm/versions/node/v22.22.1/bin/rea`.
- No pierdas tiempo con `.cmmkb`: es opaco a propósito y queda fuera de alcance.
