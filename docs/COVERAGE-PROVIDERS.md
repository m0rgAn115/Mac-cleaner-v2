# Proveedores nativos ampliados

Implementados a partir de `reverse-eng/08`, `09` y `12`, sin bases propietarias:

- Darwin (`confstr`), Electron confirmado por framework y cachés específicas Adobe, Spotify, Telegram, WeChat, Tencent y Youku. Photos conserva el archivo accedido más recientemente.
- Backups iOS por dispositivo y fecha; conserva el más reciente y las copias sin fecha conocida. Los errores de permiso no se clasifican como backup roto.
- Preferencias plist inválidas y LaunchAgents/Daemons cuyo ejecutable falta con `ENOENT`/`ENOTDIR`, conservando ejecutables de apps instaladas. Programas relativos sin ubicación comprobable quedan fuera.
- Xcode Archives, DeviceSupport de cuatro plataformas, ModuleCache, DocumentationCache, CoreSimulator Caches e iOS Device Logs. Sin eliminar manualmente dispositivos ni runtimes de simulador.
- Mail Downloads distingue archivos modificados mediante creación/modificación; se enumeran archivos y paquetes, sin eliminar carpetas UUID completas que pudieran contener más adjuntos.
- DMG en Home mediante Spotlight con timeout de 20 segundos; excluye raíces Dropbox de info.json y CloudStorage. No se presupone que una app esté instalada ni que el DMG sea prescindible.
- Papelera del usuario, iCloud y volúmenes locales escribibles: inventario sin preselección. El ejecutor integrado usa vaciado permanente explícito, con selección manual y confirmación de irreversibilidad; no se vuelven a enviar a la Papelera.
- Opcional: cachés y logs de sistema, migración y DMG de usuarios eliminados. Sin privilegios: pueden aparecer bloqueados por permisos/SIP.

## Límites y garantías

Los proveedores solamente descubren objetivos. Rust calcula tamaños, aplica exclusiones y valida identidad, descendientes, acceso y propietario al limpiar. Spotlight usa un archivo temporal para evitar bloqueo de pipes y nunca ejecuta limpieza. Un Home de fixtures deshabilita Darwin real, apps globales, Spotlight, volúmenes y rutas globales; busca DMG solo dentro del fixture.

Los proveedores complementarios integran historiales de descargas, versiones iWork, simuladores/runtimes y adjuntos con IMAP verificable; véanse los otros documentos de cobertura. Quedan fuera login items sin API pública adecuada, adjuntos de buzones sin confirmar IMAP, cachés de cuarentena SQLite y diagnósticos potencialmente peligrosos. La invalidación de `cfprefsd` para preferencias rotas necesita implementación específica antes de prometer que no reaparecerán. No se afirma paridad con helpers privilegiados de la app original.
