# Mail moderno: adjuntos y mensajes de Papelera

`MailDiscovery.discover(home:)` descubre `mailAttachments` y `mailTrash`. No duplica Mail Downloads. Rust sigue aplicando exclusiones/identidad/permisos y Swift bloquea Mail en ejecución antes de limpiar.

## Evidencia y fuentes

REA CLI 6.5.0/Ghidra 12.1.4, framework original `reverse-eng/thin/MailboxService`, SHA-256 `0938098a3fa97db0a2bb7cbd7f478f0b2987ac781acaedf8a3877a90a242b802`:

- `fetchAccountsWithError:` (`0x1cbc`), evidencia `ev_eb54a24c9dd32a4f040b720178148ca610db3c5b9e30d117063167174679903a`: tablas por sufijo ACCOUNT/ACCOUNTTYPE/DATACLASS/ENABLEDDATACLASSES; tipos `com.apple.account.IMAP` y `com.apple.account.IMAPMail`; propiedades archivadas seguras `com.apple.Dataclass.Mail`.
- `_fetchAccountStateFromTable:classIdentifier:accountId:` (`0x298c`), `ev_7c800ecdc27dd693f35ec3acc6e5c5f948325e9bde35232f2da9bdceed444ce8`: unión ENABLEDACCOUNTS/ENABLEDDATACLASSES y cuenta padre cuando existe.
- `_fetchAccountPathFromProperties:uniqueIdentifier:` (`0x2b38`), `ev_51e25901cd98d702ebd730e6a26e3cc8dbaa88c9acce65ed21c2b2fee00e0d18`: `~/Library/Mail/PersistenceInfo.plist`, `LastUsedVersionDirectoryName` y el identificador de cuenta reconstruyen la ruta activa.
- `CMMailBox.initWithInfoDictionary:` (`0x3048`), `ev_cb4cb549a7d4cd2aab89f126e2ba2850d28dcb908fae34b36ddc2101d77288f4`: `TrashMailboxName` se convierte componente por componente, por ejemplo `INBOX/Trash` → `INBOX.mbox/Trash.mbox`.
- `isOffline` (`0x38a0`), `ev_cce1a20085c6e91986878993296decd8e5c02a2a80c1eb234ee0d97545ac9772`, y `_takenOfflineWithDictionary:` (`0x3db8`), `ev_87d80adf24beee1dcf319a74e0596e1de03c44d069ac28655b61a228cbc6057d`: estado de `.mboxCache.plist`. Inspección estática adicional de constantes enlazadas confirma clave `takenOffline` y valor offline `YES`.

El SDK público macOS26.5 `Accounts.framework/Headers/ACAccount.h` expone tipo/identificador, pero no estado Mail habilitado, online ni ruta del buzón. No se usa KVC/API privada, AppleScript, credenciales ni solicitudes de acceso a cuentas. La inspección real de `~/Library/Accounts` y `~/Library/Mail` devolvió `Operation not permitted` en este entorno; no se levantó TCC ni se leyó contenido personal. Por ello no se afirma que el esquema privado actual instalado sea idéntico: se valida cada tabla/columna y, si cambia, se omite sin inferencias.

## Comportamiento

- Busca bases `Accounts*.sqlite` (incluye Accounts4 y accounts-v*) de mayor versión natural, en modo SQLite READONLY, `query_only`, transacción coherente que conserva WAL, timeout de bloqueo250ms, plazo3s y límite10000 filas. Consulta únicamente identificador, propiedades necesarias, tipos y relaciones de habilitación; nunca asuntos, remitentes, cuerpos o credenciales. No copia una base personal ni registra filas.
- Para selección automática exige IMAP/iCloud, relación Mail habilitada y `takenOffline` explícitamente `NO` o booleano false. Ausencia, permisos insuficientes o valores ambiguos omiten la cuenta. Esto es más conservador que la app original, que interpreta caché ausente como online. Online significa el estado local de Mail, no una comprobación de conectividad de red.
- Adjuntos: archivos/paquetes dentro de carpetas `attachments` (sin distinguir mayúsculas), sin ocultos, enlaces ni directorios completos. Agrupa mediante `detail` JSON `group`/`name`, clave nombre y tamaño; una coincidencia de nombre/tamaño no afirma igualdad de contenido.
- Papelera: únicamente el buzón declarado por metadatos o seleccionado explícitamente; busca carpetas `data` y acepta solo `.emlx`/`.emlxpart`. No interpreta el nombre `Trash` por sí solo ni incluye extensiones ajenas. Adjuntos de la Papelera verificada se omiten del grupo de adjuntos para evitar duplicación.
- Ambos llevan `owner=com.apple.mail` y preselección. El `detail` incluye `mailVerification` para distinguir detección verificada y declaración explícita. Paths siempre deben estar dentro de Mail, sin escapes por enlaces simbólicos.

## Selección explícita cuando TCC impide verificar

Se admite configuración **creada/importada explícitamente por el usuario** en `~/Library/Application Support/CleanMyMacLocal/mail-accounts.json`. El proveedor solo lee ese archivo, nunca lo crea ni rellena confirmaciones por defecto. API Codable `MailDiscoveryMetadata`/`MailAccountMetadata`; `MailDiscovery.configurationURL(home:)` devuelve su ubicación.

```json
{
  "version": 1,
  "accounts": [{
    "accountPath": "/Users/USUARIO/Library/Mail/V10/IDENTIFICADOR-DE-CUENTA",
    "accountType": "IMAPAccount",
    "enabled": true,
    "offline": false,
    "remoteCopyConfirmed": true,
    "trashPath": "/Users/USUARIO/Library/Mail/V10/IDENTIFICADOR-DE-CUENTA/Trash.mbox"
  }]
}
```

`accountType` debe ser `IMAPAccount` o `AosImapAccount`; `enabled`, `offline` y `remoteCopyConfirmed` son obligatorios. El usuario declara que Mail está habilitado/online y el servidor conserva la copia. POP, Exchange, cuentas offline/deshabilitadas y confirmación false quedan fuera. `trashPath` es opcional: sin él solo se ofrecen adjuntos. La declaración no concede permisos de lectura; TCC puede seguir impidiendo el escaneo. El panel «Acceso y helper» permite guardar esta declaración, con confirmación desmarcada inicialmente. La interfaz debe mostrar la garantía declarada y nunca convertir automáticamente una carpeta seleccionada en `remoteCopyConfirmed=true`.

## Validación

`MailDiscovery.validate(candidate:home:)` relee la fuente original antes de simular o limpiar, sin recorrer todos los adjuntos. Un estado offline observado, habilitación o confirmación retirada, o cambio de ruta/buzón bloquea la operación. Una declaración no sustituye silenciosamente evidencia SQLite revocada. Los resultados antiguos sin identificación de fuente requieren nuevo escaneo.

`MailDiscoveryTests.swift` cubre IMAP/iCloud permitido, POP/offline/deshabilitado/sin confirmación excluido, agrupación de copias, extensiones y ubicación de Papelera, ausencia de metadatos, escape por enlaces, SQLite sintético con habilitación por relaciones, estado online explícito y ruta de Papelera anidada. `fixtureMetadata` se acepta exclusivamente con un HOME aislado, nunca con el HOME real.

No se envían datos a la red ni se ejecutan acciones de Mail. Esta entrega no garantiza que borrar copias de adjuntos no requiera una nueva descarga ni implementa sincronización/remoción remota de mensajes; los objetivos se mueven localmente a la Papelera, con las limitaciones de la operación nativa ya documentadas.
