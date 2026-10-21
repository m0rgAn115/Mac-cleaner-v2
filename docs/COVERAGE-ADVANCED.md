# Proveedores avanzados y límites verificables

Implementación: `AdvancedDiscovery.discover(home:)`, basada en `reverse-eng/08-spec-system-junk.md` § Xcode y `reverse-eng/12-spec-detalles-de-limpieza.md` §§4–7.

- **Simuladores**: `xcrun simctl list devices -j`, únicamente UUID válidos con directorio existente en `Library/Developer/CoreSimulator/Devices`. El proveedor propone preselección si el dispositivo no está disponible; la política final del motor desactiva toda preselección de operaciones irreversibles. La retirada requiere `simctl delete <UUID>`; nunca mover la carpeta manualmente.
- **Runtimes**: `xcrun simctl runtime list -j`. Solo se entregan targets si el registro incluye UUID y ruta de imagen existente. Algunas versiones de simctl no exponen esa ruta: se informa explícitamente, sin adivinar archivos montados. La retirada requiere `simctl runtime delete <UUID>`.
- **Versiones de documentos**: Spotlight limitado al Home para los UTI iWork Pages/Numbers/Keynote y consultas de `NSFileVersion.otherVersionsOfItem(at:)`. Se excluye Dropbox por configuración `~/.dropbox/info.json`, raíz histórica y carpetas Dropbox en CloudStorage. Se ordenan todas las versiones por fecha descendente y el proveedor propone solamente las intermedias a menos de cuatro horas de la anterior. El motor descarta tamaños cero y exige selección manual por tratarse de una operación irreversible. No se recorre `.DocumentRevisions-V100` ni se interpreta su base de datos.
- **Mail moderno**: proveedor independiente con Accounts SQLite, caché de estado online y configuración explícita opcional. Ver [evidencia y límites](COVERAGE-MAIL.md).
- **Cuarentena**: preferencia avanzada y selección manual, validación del esquema SQLite, backup consistente y retirada solo de IDs presentes en el backup. El informe conserva la ruta de recuperación.
- **Diagnósticos**: detección optativa de `/private/var/db/diagnostics`; los permisos, SIP y dependencias conservan los objetivos protegidos. No hay operación root para esta ubicación.

## Contrato de ejecución

`ScanTarget.detail` contiene JSON:

- Simulador/runtime: `{"uuid":"UUID"}`.
- Versión: `{"documentPath":"/ruta/documento","versionPath":"/ruta/version"}`. Antes de retirar, el ejecutor debe reconsultar las versiones del documento y comprobar la URL; usar `NSFileVersion.remove()` sobre esa versión, nunca Papelera sobre su almacenamiento interno.

Los comandos del descubrimiento son de solo lectura y tienen límite de 20 segundos con salida en archivo temporal y limpieza del temporal. Spotlight/simctl/NSWorkspace solo se consultan cuando `home` coincide con el Home real; fixtures externos nunca disparan esos proveedores. Mail admite fixtures en su propia raíz. Los fallos parciales se devuelven como `ScanIssue`.

## Validación disponible

El host actual tiene Command Line Tools pero no encuentra `simctl`; esa ausencia se muestra como problema de proveedor. Para verificar detección real de simuladores y runtimes se requiere Xcode con sus herramientas seleccionadas. La disponibilidad de revisiones depende del historial guardado por las aplicaciones y permisos de macOS. No se ha ejecutado ninguna retirada de datos reales mediante estos proveedores.
