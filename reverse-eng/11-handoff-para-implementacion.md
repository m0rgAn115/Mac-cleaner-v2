# 11 · Handoff para el agente que implementa

Este documento es el **punto de entrada** para quien vaya a construir
funcionalidades a partir del análisis de CleanMyMac. No hace falta repetir la
ingeniería inversa: todo lo necesario está en los reportes.

> Alcance de esta carpeta: describe exclusivamente el comportamiento de
> **CleanMyMac**.

## 1. Orden de lectura

1. **03** — arquitectura del motor (árbol de nodos, selección, removers, cola).
2. **08** — System Junk: rutas, filtros y preselección exactos.
3. **09** — Papeleras, imágenes de disco y Descargas.
4. **10** — cómo se ejecuta la limpieza (borrado definitivo, privilegios,
   simulación, dependencias).
5. **07** — sandbox caches, “cierra la app primero”, leftovers y SIP.
6. **12** — detalles: Electron, rutas fijas, logs privados, simuladores, versiones de documentos, Mail, recursos de apps.
7. **06** — contratos de la lista de exclusión y *fetchers* del desinstalador.
8. **02** — catálogo general (para categorías no detalladas en 08–09 y 12).

## 2. Requisitos derivados del comportamiento de CleanMyMac

Cada requisito cita su especificación. **CMM** = lo que hace CleanMyMac.
**Decisión** = lo que el implementador debe elegir; CleanMyMac no lo impone.

### R1 · Modelo de resultado
- Árbol `grupo → ítems` con `path`, `size` y `autoselected` por ítem; los grupos
  vacíos se descartan (08 §0.1, 03 §2).
- Cada ítem lleva la categoría y, si aplica, el **bundle ID dueño** (07 #11).

### R2 · Predicados reutilizables (08 §0.2)
Implementar `Name`, `Size(limit)` (excluye si es mayor), `IsReachable`,
`Ignore(denylist)` (ruta completa **o** nombre), `Access` (archivo no
escribible) y `NOT/AND/OR`. Con esto se reproduce cualquier filtro de CMM.

### R3 · Denylist propia (06 §1, 08 §0.3)
CMM usa una base cifrada; hay que crear una propia con consultas por ruta, por
nombre, por bundle ID y por dispositivo. **Decisión:** formato (TOML/JSON) y
fuentes públicas de cada regla.

### R4 · Categorías y criterios
| Categoría | Spec | Puntos clave |
|:--|:--|:--|
| Cachés usuario, Darwin, contenedores | 08 §2, 07 #10 | hijos directos; *deep search* opcional; tamaño 0 fuera; sin edad |
| Cachés de sistema | 08 §2.1 | `/Library/Caches` + coresymbolicationd; requiere privilegios |
| Logs | 08 §3 | 7 fuentes; > 10 KB; solo si son escribibles; recursivo en directorios; sin edad |
| Preferencias rotas | 08 §4 | 7 condiciones, incluido el parseo con CoreFoundation |
| Agentes rotos | 08 §5 | resolución de ejecutable; no marcar si no hay permiso de lectura |
| Backups iOS | 08 §6 | agrupar por dispositivo; el más reciente nunca preseleccionado |
| Xcode | 08 §7 | tabla de preselección por subcategoría; simuladores vía `simctl` |
| Papeleras | 09 §1 | `~/.Trash`, iCloud y `/Volumes/*/.Trashes/<uid>` solo locales y escribibles |
| DMG | 09 §2 | Spotlight UDIF; excluir Dropbox; nada preseleccionado |
| Descargas por origen | 09 §3 | reglas de Safari, Chrome y Slack; 30 días solo en Slack |
| Leftovers | 07 #12, 12 §8 | dos fuentes de candidatos + cuatro filtros + 20 *fetchers* con coincidencia por palabras |
| Cachés Electron y rutas fijas | 12 §1–2 | Electron preseleccionado; rutas fijas no, salvo Photos |
| Versiones de documentos | 12 §5 | regla de 4 h; conservar la más nueva y la más antigua |
| Mail (adjuntos y Mail Downloads) | 12 §7 | copias agrupadas por nombre y tamaño; descargas sin modificar preseleccionadas |
| Usuarios eliminados | 12 §4 | solo `.dmg`, no preseleccionados |

### R5 · Ejecución (10, 07 #11)
- Comprobar las apps en ejecución por bundle ID antes de borrar y no borrar si
  la dependencia no se cumple.
- Resultado por ítem; actualizar el árbol tras limpiar.
- Modo simulación que recorre toda la lógica sin borrar, y modo de fallo forzado
  para tests.
- **Decisión:** CMM borra de forma definitiva; elegir si replicarlo o usar la
  Papelera por categoría (10 §6).

### R6 · Seguridad del sistema de archivos (07 #14, 10 §5)
- Rechazar archivos con xattr `com.apple.rootless`.
- **Decisión:** CMM quita los flags de bloqueo; recomendable **no** hacerlo.

## 3. Criterios de aceptación sugeridos (tests de comportamiento)

Fixtures en un HOME temporal que reproduzcan estas situaciones; el resultado
esperado es el comportamiento de CMM:

1. `~/Library/Caches/foo` con `.DS_Store` y archivos → un ítem `foo` preseleccionado; `.DS_Store` ignorado.
2. Caché de tamaño 0 → no aparece.
3. Caché Gradle → aparece **no** preseleccionada.
4. `~/Library/Containers/X/Data/Library/Caches/a` → aparece; `…/Data/Documents/b` → **no** aparece.
5. Log de 5 KB en `~/Library/Logs` → excluido; log de 50 KB → incluido y preseleccionado.
6. Directorio de logs con solo archivos ≤ 10 KB → el grupo no aparece.
7. Plist válido → no es “roto”; plist truncado → roto y preseleccionado; plist con flag inmutable → no roto; `.lockfile` → ignorado.
8. LaunchAgent con `Program` inexistente → roto; con `ProgramArguments[0]` existente → no roto.
9. Dos backups iOS del mismo dispositivo → el más reciente no preseleccionado y el otro sí; backup sin `Device Name` → grupo “roto” preseleccionado.
10. DerivedData con `ModuleCache.noindex` y `MiApp-abc` → solo `MiApp-abc` preseleccionado.
11. Volumen de solo lectura o de red → su papelera no se ofrece.
12. Descarga de Slack de hace 31 días → preseleccionada; de hace 5 días y completa → no.
13. App en ejecución con caché seleccionada → el ítem falla con “app en ejecución” y no se borra.
14. Archivo con xattr `com.apple.rootless` → rechazado.

## 4. Lo que sigue sin resolver (solo funciones de limpieza)

Alcance acordado: funciones de **limpieza**. Privacidad, Space Lens, Organize
(duplicados), Mantenimiento y Actualizador quedan **fuera de alcance**.

| Tema | Estado | Dónde mirar |
|:--|:--|:--|
| Preselección de recursos en la UI del desinstalador | Fuera del escaneo: la decide `ApplicationsModule` (UI) | `ApplicationsModule` |

Todo lo demás de las funciones de limpieza está resuelto (07–12).

Ninguno de estos puntos bloquea la implementación del resto: son detalles
dentro de categorías ya especificadas.

Para continuar el análisis: ver `05-preguntas-abiertas.md` (cómo usar Ghidra
con los slices de `thin/`).
