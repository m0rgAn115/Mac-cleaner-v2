# Descargas y posibles restos

Implementación basada en `reverse-eng/09-spec-papeleras-dmg-descargas.md` §3,
`07-decompilacion-ghidra.md` #12 y `12-spec-detalles-de-limpieza.md` §8.

- Safari: lee `DownloadHistory` de los dos `Downloads.plist` conocidos. Usa
  `DownloadEntryPath`, `DownloadEntryProgressBytesSoFar` y
  `DownloadEntryProgressTotalToLoad`. Solo preselecciona paquetes `.download`
  incompletos con Safari cerrado. Las descargas completas requieren selección.
- Chrome: perfiles desde `Local State/profile/info_cache`; consulta `current_path`
  en `History/downloads` con SQLite del sistema, `-readonly` y transacción de
  lectura coherente con WAL. Nunca modifica el historial. Tiempo máximo de 5 s
  por perfil. No preselecciona archivos.
- Slack: soporta registros JSON en `slack-downloads` y `root-state.json/downloads`
  con campos explícitos `downloadPath`, `downloadState`, `progress`, `isPaused`,
  `startTime`. Estas claves y rutas aparecen como literales en DownloadsScanning
  5.5.3 instalado; esto es evidencia secundaria, no equivalencia del esquema
  completo. Descarta en curso, pausa, estados desconocidos o campos ausentes.
  Progreso incompleto en `completed/interrupted` permite preselección; por edad
  únicamente acepta timestamps interpretables en segundos (no adivina unidades).
- Solo se incorporan rutas existentes bajo el HOME recibido, sin enlaces que
  escapen de ese HOME ni búsquedas genéricas en Descargas. Los errores de acceso
  y TCC se muestran como incidencias; fuentes inexistentes no generan ruido.
- Restos: candidatos únicamente desde preferencias y contenedores. Excluye IDs
  instalados, Apple, la propia app, nombres de apps instaladas y asociaciones
  locales observables. Estas asociaciones salen de los Info.plist de extensiones,
  login helpers, XPC y frameworks embebidos, no de una tabla propietaria ni de
  asumir que todas las aplicaciones del mismo proveedor son la misma.
- Recursos propios: hijos dentro de Library/Application Support, Caches,
  Preferences (incluido ByHost), Logs/DiagnosticReports, CrashReporter, Saved
  Application State, Cookies, LaunchAgents/LaunchDaemons, Internet Plug-Ins,
  Plug-Ins, PDF Services, Help, Application Scripts y Caches/TemporaryItems. Nunca
  se propone una raíz estructural ni hijos arbitrarios directamente en Library. No se recorre arbitrariamente HOME.
- Coincidencias: bundle ID delimitado por separadores, incluidos sufijos y
  prefijos de grupo; o todas las palabras del nombre, según spec 12 §8.2. Foo,
  Foo2 y Foo 2 se distinguen. Las coincidencias de nombre son de confianza baja,
  visibles como tales y sin selección automática. Preferencias/cachés con IDs
  conocidos tienen evidencia más fuerte, sin prometer que sean prescindibles.
- LaunchAgents/Daemons necesitan Label vinculado al ID o ejecutable dentro de
  la app elegida. Plugins con CFBundleIdentifier explícito incompatible se
  descartan aunque su nombre coincida. Se excluyen recursos vinculados a otras
  apps instaladas y directorios con nombre de proveedor compartido.
- Contenedores enteros solo con propietario correspondiente (metadata local o
  bundle ID exacto). Group Containers solo desde application-groups de firma
  verificada mediante Security, sin otro propietario instalado conocido;
  nunca por palabras/vendor ni metadata de formato supuesto. No se duplican
  descendientes de un contenedor propuesto.

## API de revisión para desinstalación

`RelatedFilesDiscovery.resources(for: URL, home: URL)` devuelve la `.app` en
categoría `applications` y sus recursos en `leftovers`, con owner original,
selección manual y detalle de pertenencia/confianza. Solo acepta `.app` dentro
de `/Applications` o `~/Applications`, sin enlaces, flags SIP/inmutables ni apps
Apple o propias. Con HOME de fixture, solo considera Applications del fixture.
Este proveedor no mueve archivos, ejecuta apps ni modifica login items.

Limitaciones: no hay base propietaria para asociaciones históricas de IDs o
nombres, denylist completa ni equivalencia de los veinte fetchers originales.
Los nombres de restos se deducen del último componente del ID cuando falta la
app. Las coincidencias heurísticas requieren revisión de contenido. No se usan
pkgutil/recibos, Dock, login items internos ni descargas como prueba de
pertenencia para desinstalar; tampoco /Library global, /System ni temporales
arbitrarios fuera de Library. Los grupos asociados a apps ya desinstaladas no
se inventan al no quedar firma/metadata fiable. Formatos nuevos de Safari y
esquemas alternativos de Slack quedan pendientes; no se interpretan claves
ambiguas. La validación final corresponde al motor, antes de cada operación.

Pruebas: HOME temporal para Foo/Foo2, ByHost/cookies, apps instaladas y helper
embebido, recursos de proveedor compartido, grupos sin pertenencia demostrable,
LaunchAgents/Plugins con identidad incompatible, Apple/self y raíces/enlaces
no permitidos. No se modifica ningún recurso del usuario en estas pruebas.
