# Helper privilegiado: activación y límites

El backend usa `SMAppService.daemon` y `NSXPCConnection` en macOS 26. No instala servicios al compilar o abrir la app. No utiliza sudo, shells root, AuthorizationExecuteWithPrivileges ni comandos suministrados por el cliente.

## Estado real de esta instalación

La aplicación local está firmada ad hoc y no hay identidades válidas de firma disponibles. Por política de autenticación de este proyecto, **la función privilegiada permanece bloqueada**: `PrivilegedClient.status()` devuelve `.unavailable` con la causa. Esta política exige firma Apple con Team ID y hardened runtime para ambos procesos. No se afirma que toda configuración ad hoc esté universalmente prohibida por SMAppService.

Apple documenta el registro sujeto a aprobación del usuario en [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). El encabezado `SMAppService.h` del SDK 26.5 especifica firma para las apps y notarización para las que contienen LaunchDaemons. Por ello una compilación local ad hoc **no se presenta como un helper instalado ni autorizado**. Compilación y pruebas de fixtures no acreditan registro, aprobación ni ejecución root.

## Empaquetado y firma

La aplicación debe contener:

```
CleanMyMacLocal.app/
  Contents/Info.plist
  Contents/MacOS/CleanMyMacLocal
  Contents/Library/HelperTools/CleanerHelper
  Contents/Library/LaunchDaemons/local.cleanmymac.CleanMyMacLocal.helper.plist
```

El plist del daemon debe declarar:

- `Label`: `local.cleanmymac.CleanMyMacLocal.helper`.
- `BundleProgram`: `Contents/Library/HelperTools/CleanerHelper`.
- `MachServices`: diccionario con `local.cleanmymac.CleanMyMacLocal.helper = true`.
- `UserName`: `root`.
- `AssociatedBundleIdentifiers`: array con `local.cleanmymac.CleanMyMacLocal`.

El script de empaquetado recibe la identidad mediante `CLEANER_SIGN_IDENTITY`; sin esa variable mantiene la firma ad hoc y el bloqueo privilegiado. Ejemplo: `CLEANER_SIGN_IDENTITY="Developer ID Application: Nombre (TEAMID)" ./scripts/build.sh`. No es necesario guardar secretos en el repositorio.

Firma primero el ejecutable helper con identificador `local.cleanmymac.CleanMyMacLocal.helper` y luego la app con identificador `local.cleanmymac.CleanMyMacLocal`, usando la misma identidad Apple/Team ID, hardened runtime (`codesign --options runtime`) y sin `get-task-allow`. Distribuye el paquete notarizado. La app verifica que la firma del helper coincide con su Team ID antes de registrar o conectar.

Ubica la aplicación final en `/Applications`, tal como recomienda [Apple para LaunchDaemons](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:)). El usuario pulsa la acción de activar helper: la app llama a `register()`, y macOS determina si requiere aprobación en Ajustes del Sistema → General → Ítems de inicio y extensiones. `openApprovalSettings()` abre ese panel. La interfaz debe mostrar el estado devuelto por macOS y cualquier error de registro, sin sustituirlo por un supuesto éxito. Para desactivar, `unregister()` solicita a SMAppService retirar el registro. No se ejecutaron estas operaciones en el equipo de desarrollo.

## Identidad y contrato XPC

El listener y cada conexión aplican requisitos de firma con ancla Apple, Team ID e identificador exactos. [`setCodeSigningRequirement`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)) invalida mensajes que no cumplen el requisito. Además, se verifica la firma dinámica de `SecCode` para el PID de la conexión y se vinculan PID/UID a la sesión; nunca se autoriza solo por UID. El requisito aplicado por NSXPC conserva la vinculación con el peer real, evitando depender únicamente de un PID reutilizable.

`PrivilegedProtocol` expone operaciones enumeradas `scanSystem`, `validate` y `remove`, codificadas como JSON en NSData. No admite rutas de operación ni ejecutables arbitrarios. Los tokens UUID y snapshots se generan y conservan únicamente en el helper, por conexión. Un nuevo escaneo reemplaza los anteriores; caducan a los 15 minutos. Las exclusiones de rutas/nombres solo reducen lo permitido y se comprueban contra el árbol completo antes de validar o retirar. Un token capturado se consume incluso si la captura debe restaurarse.

## Escaneo y eliminación

Las únicas raíces de producción son `/Library/Caches` y `/Library/Logs`. Cachés se ofrecen por hijo directo; logs por archivo mayor de 10 240 bytes. No se entra en `/System`, diagnósticos ni rutas `com.apple.*`. No se recorren enlaces. Árboles con elementos ocultos, protegidos o excluidos se conservan completos. Todos los candidatos requieren selección manual.

Se exige propietario root, sin escritura de grupo/otros, sin ACL extendidas, sin enlaces duros en archivos, sin flags SIP/inmutable/append, y ancestros verificados. La única excepción de escritura es la raíz fija `/Library/Caches`: macOS normalmente la configura sticky 1777; su propietario root y el sticky bit impiden a clientes sustituir sus entradas root-owned. Los descendientes no reciben esa excepción.

La retirada requiere `confirmed: true`, que la app solo debe transmitir después de confirmar **eliminación definitiva**, cantidad y tamaño. El helper revalida el snapshot de metadatos del árbol, abre rutas relativas a descriptores con `O_NOFOLLOW` y captura mediante `renameatx_np(RENAME_EXCL)` en `/Library/Caches/local.cleanmymac.CleanMyMacLocal.helper.quarantine`, root-owned 0700, sin ACL. Si no es el mismo volumen, rechaza la operación. Tras comprobar de nuevo la identidad y el árbol capturado, elimina únicamente entradas del snapshot con `unlinkat`; los directorios solo se retiran vacíos. No vacía la Papelera ni crea una Papelera para root.

Ante cambios/fallos, restaura el contenido restante con `RENAME_EXCL`, sin sobrescribir. Si el nombre original ya existe, conserva la captura y devuelve `quarantinePath` para revisión. Un fallo puede ocurrir después de retiradas parciales: el resultado indica cuántas entradas ya desaparecieron. La aplicación debe persistir ese informe, incluida la ruta de cuarentena. El helper no elimina automáticamente capturas retenidas en ejecuciones posteriores; el siguiente escaneo las vuelve a reportar como incidencias, incluyendo la ruta, para cubrir también interrupciones o crashes.

El modelo protege contra sustituciones por procesos **no privilegiados**. No pretende proteger de un atacante con root/kernel. Otros procesos root aún pueden mantener archivos abiertos o modificar datos; los snapshots detectan cambios de metadatos pero no son hashes del contenido. La limpieza no es transaccional y puede dejar resultados parciales. Un timeout de cliente deja resultado desconocido: hay que volver a escanear y revisar el informe antes de reintentar.

## Verificación sin privilegios

```
swift build --target CleanerHelper --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
.build/out/Products/Debug/CleanerHelper --self-test
```

`--self-test` genera fixtures temporales del usuario, adapta la política de propietario **solo para esos fixtures internos**, y no abre las raíces de producción ni un listener XPC. Rechaza ejecutarse como root. Comprueba umbral de logs, enlaces simbólicos/duros, permisos inseguros, exclusiones descendientes, cambios posteriores al escaneo, confirmación, retirada, restauración y retención sin sobrescritura. Se ejecutó correctamente en desarrollo. `CleanerCore` también compila con ese SDK. La prueba de extremo a extremo de firma, autorización del sistema y limpieza root queda pendiente de disponer de una identidad válida y aprobación explícita del usuario.
