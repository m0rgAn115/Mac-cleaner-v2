# CleanMyMacLocal 0.3

Aplicación local en español para **macOS 26 o posterior**, validada inicialmente en Apple Silicon. SwiftUI/AppKit presentan los resultados; una biblioteca Rust estática escanea y valida los objetivos. Las funciones locales no requieren Xcode completo, cuenta ni servidor. El helper opcional se registra solo por acción explícita.

## Compilar y abrir

Requisitos: Command Line Tools con Swift 6, Cargo/Rust estable y un SDK de macOS compatible con el compilador instalado. Los scripts prefieren el SDK 26.5 si está disponible; el SDK 27 de este equipo requiere macros SwiftUI ausentes en sus Command Line Tools. Se puede elegir otro SDK con `CLEANER_SDK=/ruta/al/sdk`.

Desde la raíz:

```sh
./scripts/build.sh
open build/CleanMyMacLocal.app
```

La primera compilación descarga las dependencias Rust fijadas en `engine/Cargo.lock`. El script empaqueta el helper y genera y verifica una firma ad hoc, para uso local. `CLEANER_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build.sh` firma ambos procesos con hardened runtime; sin una identidad Apple válida, la app bloquea la activación privilegiada. Ver [helper](PRIVILEGED.md). No instala la app en `/Applications` ni modifica la configuración global de las herramientas. `Package.swift` también se puede abrir con Xcode; primero hay que compilar la biblioteca Rust con el script.

## Uso

1. Escanear. Las ubicaciones inexistentes se omiten; los errores de acceso se muestran como incidencias.
2. Revisar categorías, rutas y tamaños, y ajustar la selección. Los grupos tienen selección parcial; el buscador filtra por ruta o nombre.
3. Simular para verificar los objetivos sin moverlos, o confirmar el traslado a la Papelera.
4. Revisar el informe por elemento. Solo los traslados correctos desaparecen del árbol.

El menú ofrece «Revisar una aplicación» para elegir un .app y sus recursos asociados, con selección manual y protección de Apple, la propia app y recursos compartidos identificados.

Se incluyen cachés de usuario, contenedores, Darwin, Electron, rutas específicas de aplicaciones y sistema; logs de usuario, contenedores y sistema; backups iOS; preferencias y agentes rotos; DMG mediante Spotlight; historiales Safari, Chrome y Slack; posibles restos de apps; Mail Downloads, adjuntos verificables y papelera IMAP/iCloud; archivos, soporte de dispositivos, módulos y documentación Xcode; cachés, dispositivos y runtimes CoreSimulator; papeleras y versiones iWork. Los proveedores no disponibles o sin acceso se muestran como incidencias; una categoría vacía no afirma que todo el disco esté limpio. Las cachés de tamaño cero y `.DS_Store` no aparecen. Los logs deben ser escribibles y mayores de 10 240 bytes. Gradle y los directorios ModuleCache/SymbolCache de DerivedData no se preseleccionan. No hay filtro de edad.

Los tamaños asignados son una estimación del espacio físico ocupado; el menú permite mostrar tamaños lógicos por fila. No se promete recuperación exacta en APFS con compresión, clones o snapshots. **Mover a la Papelera no libera espacio hasta vaciarla.** Los elementos ya en la Papelera usan vaciado definitivo; dispositivos y runtimes se retiran con `simctl`, y versiones mediante `NSFileVersion.remove()`. Estas operaciones irreversibles nunca se preseleccionan y la confirmación indica expresamente su cantidad. No se borran carpetas de simuladores manualmente.

## Seguridad y persistencia

Rust descubre candidatos únicamente dentro de las raíces admitidas y conserva su identidad y una huella de metadatos de sus descendientes. La ejecución recibe identificadores, nunca rutas arbitrarias. Antes de cada traslado se vuelven a comprobar identidad, exclusiones, permisos, flags inmutables, atributos SIP y apps propietarias en ejecución. Los enlaces simbólicos (salvo enlaces internos de paquetes .app, que se mueven sin seguir sus destinos), archivos especiales, hardlinks compartidos y carpetas con descendientes excluidos o protegidos quedan bloqueados u omitidos.

La propiedad se establece por bundle ID, nombre exacto y no ambiguo de una aplicación instalada, metadatos del contenedor o asociación explícita documentada. La caché compartida Google se divide por aplicación; Chrome mantiene su propia dependencia. Si no se identifica al propietario, la UI lo indica: no se garantiza detectar procesos de fondo sin bundle ID ni todos los archivos abiertos. La API de Papelera trabaja con rutas y deja una ventana de carrera después de validar; no ofrece una transacción atómica. No hay fallback a borrado definitivo ante errores de traslado, modificación de flags ni escalado root como alternativa ante fallos. El borrado definitivo solo corresponde a categorías con operación explícita. El helper opcional tiene raíces y operaciones restringidas, selección manual y autenticación XPC; no sustituye un traslado fallido. El historial de cuarentena es optativo y conserva una copia SQLite privada, disponible desde el informe.

El escaneo es cancelable. Una cancelación invalida la sesión para futuras limpiezas y requiere volver a escanear. Durante una limpieza, las operaciones ya terminadas se conservan; un traslado nativo ya iniciado no se interrumpe a la mitad.

Las reglas propias versionadas se incluyen en `Sources/CleanerCore/Resources/rules.json`. Las exclusiones y los informes JSON se guardan bajo `~/Library/Application Support/CleanMyMacLocal/`, con directorios privados y archivos de modo 0600. El menú contextual excluye rutas; el diálogo de exclusiones permite retirarlas. También se admiten `names` y `bundle_ids` editando `exclusions.json` (versión 1). Si el archivo es inválido, se detiene el escaneo en vez de ignorarlo. Después de modificar exclusiones, volver a escanear.

Preferencias de visualización: UserDefaults. Sin App Sandbox; las restricciones de macOS/TCC se respetan y aparecen como incidencias. La app no configura permisos de disco automáticamente. «Acceso y helper» muestra restricciones y permite iniciar explícitamente el registro del servicio; la aprobación la gestiona macOS. Mail moderno consulta Accounts SQLite y metadatos de Mail; si estos no verifican una cuenta, permite declarar explícitamente IMAP/iCloud online con copia remota. Ver [Mail](COVERAGE-MAIL.md).

## Validación

```sh
./scripts/test.sh
cargo test --release --manifest-path engine/Cargo.toml benchmark_fixture_scan -- --ignored --nocapture
```

Las pruebas Rust cubren categorías, umbrales, preselección, exclusiones, enlaces, cambios de identidad, inmutabilidad, permisos, cancelación y buffers ABI. Swift Testing verifica el puente completo, simulación, fallos parciales e inducidos, configuración e informes. Una prueba mueve **solo un archivo generado** a la Papelera y lo recupera inmediatamente.

El benchmark genera 2 048 archivos, comprueba 64 candidatos y 524 288 bytes lógicos, mide nueve escaneos con cuatro trabajadores y limpia sus fixtures. Mide metadatos con caché caliente/mixta, no disco frío ni rendimiento de la interfaz. No se compara con CleanMyMac ni se extrapolan las ganancias del prototipo anterior.

Para comprobar visualmente la app sin escanear archivos personales:

```sh
open build/CleanMyMacLocal.app --args --fixture-home /ruta/absoluta/a/home-temporal
```

En este modo, las exclusiones e informes van a `.cleaner-test` dentro del HOME temporal. La app inicia preparada y solo escanea al pulsar el botón.

Límites pendientes de paridad: activación y validación real del helper con firma Apple y aprobación de macOS, login items sin ejecutable verificable, invalidación de cfprefsd, limpieza privilegiada de diagnósticos, esquemas alternativos de cuentas Mail e historiales, asociaciones de leftovers fuera de las raíces documentadas, notarización y validación Intel. Simuladores requieren Xcode; el entorno actual solo tiene Command Line Tools. Versiones usan UTI iWork documentados y quedan bloqueadas si no son accesibles. Las APIs de macOS y las reglas propias no sustituyen la base propietaria del producto original.

Detalles por proveedor y diferencias respecto al comportamiento observado: [proveedores](COVERAGE-PROVIDERS.md), [descargas y restos](COVERAGE-RELATED.md), [proveedores avanzados](COVERAGE-ADVANCED.md). En el menú de opciones se puede abrir Acceso completo al disco; el usuario concede ese permiso en Ajustes y vuelve a escanear.
