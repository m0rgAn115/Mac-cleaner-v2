**Experimento de motor local: Swift frente a Rust — 2026-10-15**

La evidencia de este experimento favorece **SwiftUI/AppKit para la interfaz e integraciones de macOS, con un motor Rust enlazado mediante una ABI C pequeña**. En los dos casos grandes, el prototipo híbrido tarda un 15–22 % menos que Swift/POSIX y un 46–50 % menos que Swift/Foundation, con cuatro trabajadores y contando el arranque del proceso.

Esta es una decisión para el escaneo de metadatos implementado aquí y el equipo medido. No demuestra que Rust sea universalmente más rápido que Swift, ni que toda la aplicación vaya a acelerar en la misma proporción.

**Equipo y compilación**

- Apple M3, arm64, macOS 26.6.2.
- Swift 6.4: `-O -whole-module-optimization`.
- Rust 1.98.1: `-C opt-level=3 -C codegen-units=1 -C lto=thin`.
- Sin dependencias externas ni descargas. Python 3 solo genera datos, valida y mide los procesos.
- Fuentes: [scanner.swift](scanner.swift), [scanner.rs](scanner.rs), [bridge.swift](bridge.swift), [bridge.rs](bridge.rs), [bridge.h](bridge.h), [bench.py](bench.py).
- Mediciones individuales y comandos exactos de compilación: [results.json](results.json).

**Qué se comparó**

| Implementación | Enumeración y metadatos | Ejecución |
|---|---|---|
| Swift/Foundation | `contentsOfDirectory`, propiedades de URL precargadas, `autoreleasepool` por directorio | Cola de operaciones limitada |
| Swift/POSIX | `opendir`, `readdir`, `d_type`, `lstat` para archivos y tipos desconocidos | La misma cola limitada |
| Rust/std | `read_dir`, `file_type`, `metadata` para archivos | Trabajadores con hilos estándar |
| Swift → Rust | El mismo motor Rust, enlazado como biblioteca estática | Una llamada ABI C por escaneo |

La comparación de Swift/POSIX evita atribuir toda la diferencia con Foundation al lenguaje. Los algoritmos y resultados son equivalentes para estas fixtures; las bibliotecas, asignaciones, rutas de acceso al sistema y planificadores no son idénticos. No se hizo una prueba que aislara exclusivamente el coste del lenguaje.

Cada trabajador toma categorías independientes y recorre sus directorios con una pila. Se cuentan entradas de archivos, directorios, enlaces, bytes lógicos y candidatos. Un candidato es un `.cache` de tamaño mayor que cero o un `.log` de más de 10 240 bytes. Se omiten `.DS_Store`, subárboles `.protected` y enlaces simbólicos. Estas reglas reducidas sirven para comparar el motor, no constituyen la política de limpieza de la aplicación.

**Datos y verificación**

| Caso | Entradas de archivo | Directorios recorridos | Enlaces omitidos | Candidatos |
|---|---:|---:|---:|---:|
| Pequeño | 520 | 24 | 24 | 241 |
| Ancho | 24 592 | 32 | 48 | 10 765 |
| Anidado | 36 880 | 784 | 48 | 16 624 |

Hay nombres Unicode, archivos vacíos, tamaños justo en el umbral y por encima, enlaces circulares y rotos, hardlinks y subárboles excluidos. Los hardlinks se cuentan por entrada, no por inode ni bloques únicos.

Una implementación independiente en Python calcula la referencia. Pasaron **48 configuraciones de calentamiento y validación, más 432 ejecuciones medidas**, con igualdad en los siete agregados: archivos, directorios, enlaces, bytes, candidatos, bytes seleccionados y errores. Todos los errores fueron cero. No se comparan listas completas de rutas porque los prototipos producen resúmenes.

Las fixtures ocupan aproximadamente 204 MiB físicos; sus tamaños lógicos suman unos 2,1 GiB. Los archivos no vacíos contienen un pequeño prefijo escrito y el resto puede ser sparse. El benchmark consulta metadatos; no lee el contenido. Datos generados, binarios y caché de compilación quedan ignorados por Git dentro de esta carpeta.

**Método de medición**

Se probaron 1, 2, 4 y 8 trabajadores. Cada configuración tuvo un calentamiento y nueve repeticiones. El orden de las 48 configuraciones se aleatorizó en cada ronda con semilla fija. La generación y compilación quedan fuera del tiempo de escaneo.

El tiempo total se mide desde el lanzamiento hasta la terminación del proceso. Cada ejecutable también informa el tiempo interno, desde el descubrimiento de categorías hasta la agregación final. `wait4` entrega CPU de usuario más sistema y RSS máximo por proceso; en Darwin el RSS se expresa en bytes. Las tablas muestran medianas. Los mínimos y máximos están en el JSON.

La creación de fixtures, la referencia y el calentamiento tocan los metadatos: **son resultados de caché caliente/mixta**. No se vaciaron cachés del sistema ni se simula un disco frío. La carga de otras aplicaciones no se controló y hay variación entre ejecuciones.

**Resultados con cuatro trabajadores**

Tiempo total, incluido el arranque:

| Implementación | Pequeño, ms | Ancho, ms | Anidado, ms |
|---|---:|---:|---:|
| Rust/std | 3,47 | 27,61 | 45,11 |
| Swift/POSIX | 6,73 | 36,10 | 53,57 |
| Swift/Foundation | 7,64 | 55,78 | 84,00 |
| Swift → Rust | 4,89 | 28,11 | 45,57 |

Tiempo interno de escaneo:

| Implementación | Ancho, ms | Anidado, ms |
|---|---:|---:|
| Rust/std | 24,74 | 42,25 |
| Swift/POSIX | 31,68 | 49,16 |
| Swift/Foundation | 51,58 | 80,37 |
| Swift → Rust | 24,41 | 41,53 |

CPU acumulada y memoria máxima de todo el proceso de prueba:

| Implementación | CPU ancho, ms | CPU anidado, ms | RSS ancho, MiB | RSS anidado, MiB |
|---|---:|---:|---:|---:|
| Rust/std | 95,24 | 164,97 | 1,81 | 1,91 |
| Swift/POSIX | 117,77 | 188,38 | 7,42 | 7,50 |
| Swift/Foundation | 191,31 | 302,00 | 14,38 | 8,19 |
| Swift → Rust | 95,51 | 156,80 | 5,94 | 6,02 |

El híbrido conserva el rendimiento del motor Rust. Las diferencias de tiempo interno entre Rust solo y el híbrido están dentro de la variación observada; no implican que llamar desde Swift acelere Rust. El híbrido añade aproximadamente 0,5 ms de tiempo total en los casos grandes, comparando medianas, pero esto incluye arranque y variación y no es una medición aislada del coste FFI. El RSS incluye bibliotecas/runtime, y no representa la memoria de una futura interfaz SwiftUI.

**Concurrencia: cuatro trabajadores como punto de partida**

| Swift → Rust | 1 trabajador | 2 trabajadores | 4 trabajadores | 8 trabajadores |
|---|---:|---:|---:|---:|
| Tiempo total ancho, ms | 80,39 | 48,01 | 28,11 | 28,47 |
| Tiempo total anidado, ms | 137,34 | 77,28 | 45,57 | 45,23 |
| CPU ancho, ms | 77,97 | 90,82 | 95,51 | 161,11 |
| CPU anidado, ms | 136,40 | 149,28 | 156,80 | 272,26 |

Pasar de cuatro a ocho apenas cambia el tiempo del híbrido, pero aumenta la CPU acumulada aproximadamente un 69–74 %. Empezaría con un máximo de cuatro trabajadores para este equipo, ajustándolo con mediciones en otros discos y equipos. CPU acumulada no equivale a una medición de energía ni de autonomía.

**Stack recomendado a partir de estos resultados**

- SwiftUI y AppKit para la interfaz.
- Swift para permisos, `NSWorkspace`, Spotlight, versiones de documentos y ServiceManagement/XPC cuando sean necesarios.
- Rust para enumeración, tamaños, reglas y planificación del motor; ninguna limpieza se implementó en este experimento.
- Biblioteca Rust estática con una interfaz ABI C pequeña. En producción, entregar resultados por lotes y controlar explícitamente propiedad de memoria, errores, cancelación y progreso.
- Cuatro trabajadores de escaneo como valor inicial, sin crear un hilo por archivo.
- No añadir un runtime asíncrono al motor solo para recorrer el sistema de archivos; este prototipo usa hilos estándar.

**Reproducción**

Desde la raíz del repositorio:

```sh
python3 experiments/swift-rust/bench.py --rounds 9 --cpu 'Apple M3'
```

El parámetro `--cpu` es una etiqueta del informe; indicar el modelo real al repetir en otro equipo. Se pueden seleccionar los límites con `--workers 1 2 4 8`. El script reutiliza sus fixtures, recompila en modo optimizado y reemplaza `results.json`. Los tiempos de compilación guardados son orientativos, con cachés posiblemente calientes; no son una comparación de builds limpios. El tamaño del ejecutable Swift usa bibliotecas del sistema y no es comparable directamente con un binario Rust o una biblioteca estática como tamaño de distribución.

No se ejecutaron limpiezas ni se recorrieron archivos personales. Quedan sin medir disco frío, volúmenes externos, presión de memoria, árboles de millones de entradas, modelos completos de resultados, UI, cancelación, permisos denegados, cambios concurrentes de archivos y operaciones privilegiadas. El código es un benchmark sobre árboles estables, no un ejecutor seguro de borrado: Rust no elimina por sí solo las carreras de rutas ni los riesgos de pérdida de datos.
