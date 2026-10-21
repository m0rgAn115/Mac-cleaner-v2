# Stack principal

Aplicación local y nativa para macOS, con **interfaz SwiftUI y motor Rust**. Apple Silicon será la primera plataforma de validación.

| Área | Tecnología y responsabilidad |
|---|---|
| Interfaz | **SwiftUI**, con **AppKit** cuando sea necesario |
| Integración con macOS | **Swift 6**: permisos, `NSWorkspace`, Spotlight y versiones de documentos |
| Motor | **Rust estable**: escaneo, cálculo de tamaños, reglas y planificación de limpieza |
| Comunicación | Biblioteca Rust estática con **ABI C pequeña**, resultados por lotes y propiedad de memoria explícita |
| Concurrencia | Trabajadores limitados con hilos estándar de Rust; máximo inicial de **4**, ajustable según mediciones |
| Reglas | **JSON versionado**, con exclusiones propias y criterios por categoría |
| Persistencia inicial | **UserDefaults** para preferencias y archivos locales para exclusiones e informes |
| Herramientas | **Xcode + Swift Package Manager**, **Cargo** y **rustfmt** |
| Pruebas y rendimiento | **Swift Testing**, **cargo test**, **Instruments** y benchmarks reproducibles |

La interfaz consume resultados del motor y presenta selección, progreso y errores. Las integraciones de Apple permanecen en Swift. Las operaciones privilegiadas, cuando se incorporen, usarán un helper con **ServiceManagement/XPC** y operaciones limitadas.

El motor debe permitir simulación, cancelación y resultados por ítem. Antes de limpiar, debe volver a validar objetivos, permisos y dependencias. Las reglas de seguridad son independientes de la optimización de rendimiento.

## Evidencia de la decisión

En un Apple M3, el prototipo **Swift → Rust** tardó un **15–22 % menos que Swift/POSIX** y un **46–50 % menos que Swift/Foundation** en los dos escenarios grandes, con cuatro trabajadores. Pasar a ocho apenas redujo la latencia y aumentó la CPU acumulada un 69–74 %.

Se verificaron 432 ejecuciones medidas. Son pruebas de metadatos sobre datos sintéticos con caché caliente/mixta; la aplicación completa y el disco frío requieren validación adicional. Fuentes y resultados: [experiments/swift-rust/README.md](experiments/swift-rust/README.md).
