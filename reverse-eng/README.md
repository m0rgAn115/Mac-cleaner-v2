# Reverse engineering de CleanMyMac 5

Investigación de **CleanMyMac 5.5.3 (Mac App Store)** con
[REA](https://github.com/morluto/rea) y Ghidra para documentar *qué* limpia y
*cómo* funciona su motor de escaneo y limpieza.

**Alcance**: solo las **funciones de limpieza** de CleanMyMac (categorías,
ubicaciones de macOS, criterios de selección y ejecución). Privacidad, Space
Lens, Organize, Mantenimiento y Actualizador están fuera de alcance. **No** se copia código, assets ni
bases de reglas propietarias.

> **¿Vas a implementar?** Lee primero [11-handoff-para-implementacion.md](11-handoff-para-implementacion.md).

## Cómo leer esta carpeta

| Archivo | Contenido |
|:--|:--|
| [00-metodo-y-entorno.md](00-metodo-y-entorno.md) | Instalación de REA y Ghidra, versiones, comandos, índice de Evidence |
| [01-arquitectura-del-bundle.md](01-arquitectura-del-bundle.md) | Anatomía del .app, sandbox, entitlements, login items, frameworks |
| [02-catalogo-de-escaneo.md](02-catalogo-de-escaneo.md) | Todas las categorías de escaneo por módulo, con evidencia |
| [03-motor-de-limpieza-y-seguridad.md](03-motor-de-limpieza-y-seguridad.md) | Árbol de nodos, selección, cola de tareas, removers, privilegios |
| [05-preguntas-abiertas.md](05-preguntas-abiertas.md) | Checklist de lo respondido y lo pendiente |
| [06-metadatos-objc-y-knowledge-bases.md](06-metadatos-objc-y-knowledge-bases.md) | Clases e ivars ObjC, contratos de las listas de exclusión, *fetchers* del desinstalador |
| [07-decompilacion-ghidra.md](07-decompilacion-ghidra.md) | Cachés sandboxed, “cierra la app primero”, criterio de leftovers, SIP |
| [08-spec-system-junk.md](08-spec-system-junk.md) | **Spec** System Junk: rutas, predicados, filtros, preselección |
| [09-spec-papeleras-dmg-descargas.md](09-spec-papeleras-dmg-descargas.md) | **Spec** Papeleras, imágenes de disco y Descargas |
| [10-spec-ejecucion-de-limpieza.md](10-spec-ejecucion-de-limpieza.md) | **Spec** borrado (definitivo, privilegios, simulación, dependencias) |
| [12-spec-detalles-de-limpieza.md](12-spec-detalles-de-limpieza.md) | **Spec** Electron, rutas fijas, logs privados, simuladores, versiones de documentos, Mail, recursos de apps |
| [11-handoff-para-implementacion.md](11-handoff-para-implementacion.md) | **Punto de entrada para implementar**: requisitos, tests de aceptación, pendientes |
| `thin/` | Slices arm64 de los frameworks, para Ghidra |
| `dispatch/` | Resúmenes de metadatos ObjC por framework |
| `evidence/` | JSON de Evidence de REA (fuente de verdad, con SHA-256) |
| `symbols/` | Símbolos Swift exportados y demangleados, un archivo por framework |
| `strings/` | Literales tipo ruta extraídos con `strings` por framework |
| `tools/` | `reproduce.sh` (regenera evidence/symbols/strings), `demangle_exports.py`, `summarize_dispatch.py` |

`thin/`, `dispatch/`, `evidence/`, `symbols/` y `strings/` están en
`.gitignore`: salen del binario propietario y no deben publicarse. Los `.md`
contienen solo descripciones y conclusiones propias.

(El número 04 no existe: se retiró porque no trataba de CleanMyMac.)

## Cómo retomar el análisis

1. El MCP `rea` está registrado en `~/.claude-personal/.claude.json`, fijado a
   Node 22.22.1 y con Ghidra 12.1.4 (`~/Applications/ghidra_12.1.4_PUBLIC`).
2. Ghidra no acepta Mach-O universales: usa los slices de `thin/` o crea uno
   nuevo con `lipo <binario> -thin arm64 -output thin/<Framework>`.
3. Lee `05-preguntas-abiertas.md` y 11 §4 para elegir qué falta.
4. Si cambia la versión de CleanMyMac, ejecuta `tools/reproduce.sh` y compara.

## Conclusiones en 30 segundos

- **~120 frameworks modulares**: uno `*Scanning` por área más un núcleo común
  (`ScanningCore`, `CleaningCore`, `NodesCore`, `FileManagerService`).
- Las reglas viven en una base cifrada (`Resources/info.cmmkb`, no analizada).
  Por sus protocolos es sobre todo una **lista de exclusiones**: las
  ubicaciones están en el código (06).
- **Sin filtro de antigüedad** en System Junk. La preselección es por
  categoría; el único umbral de días (30) es para descargas de Slack (08, 09).
- **Logs**: solo archivos de más de 10 KB y escribibles, todos preseleccionados (08 §3).
- **Borra de forma definitiva**, no a la Papelera; escala privilegios cuando
  hace falta y tiene modo simulación (10).
- **Antes de borrar** comprueba por bundle ID que la app no esté abierta, y
  después la reabre en segundo plano (07 #11).
- Edición MAS **sandboxed**: acceso a Home/Applications con bookmarks y un
  agente privilegiado para operaciones root (01).
