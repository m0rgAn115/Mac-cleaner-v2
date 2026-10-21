# 00 · Método y entorno

Fecha del análisis: 2026-10-15.

## Objetivo

| Campo | Valor |
|:--|:--|
| App | `/Applications/CleanMyMac_5_MAS.app` |
| Bundle ID | `com.macpaw.CleanMyMac-mas` |
| Versión | 5.5.3 (build `50503.0.2604291229`) |
| SHA-256 del árbol (REA) | `0f738d83256252f94fe8b860574e3111dd7619861d286f01ce0dab5ad4a336af` |
| SDK / Xcode | macOS 26.0 SDK, Xcode 26.0 (17A324) |
| Mínimo macOS | 11.0 |
| Arquitecturas | Universal (x86_64 + arm64) |
| Tamaño | 193 MB |

## Herramientas

- **REA 6.5.0** (`rea-agents`), instalado con `rea setup --client claude_code`:
  - MCP registrado en `~/.claude-personal/.claude.json` → `mcpServers.rea`
    (backup en `~/.claude-personal/.claude.json.rea.backup`).
  - Comando ajustado a mano para usar
    `~/.nvm/versions/node/v22.22.1/bin/npx` con `PATH` propio, porque el
    `node` por defecto (23.1.0) está fuera del rango soportado
    (22.x ≥22.19, 24.x ≥24.11 o 26+).
  - Skill en `~/.claude-personal/skills/reverse-engineer-anything`.
  - CLI `rea` instalado globalmente bajo Node 22.22.1.
- `swift-demangle` de Command Line Tools para demanglear exports.
- `strings` para literales tipo ruta (evidencia secundaria, no REA).

**Sesión 1 sin motor nativo** (Ghidra/Hopper/IDA). Por eso el análisis llegó hasta:
inventario, plists, firma/entitlements, load commands, imports/exports y
strings. **No** hay pseudocódigo ni grafos de llamadas.

## Ghidra (instalado en la sesión 2)

- **Ghidra 12.1.4** desde el release oficial de GitHub
  (`ghidra_12.1.4_PUBLIC_20260921.zip`, SHA-256
  `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`, verificado),
  extraído en `~/Applications/ghidra_12.1.4_PUBLIC`.
- La release no incluye el decompilador nativo para macOS arm64; se compiló con
  `support/gradle/gradlew buildNatives` (JDK 21 de sdkman, clang de CLT).
  Binario: `Ghidra/Features/Decompiler/build/os/mac_arm_64/decompile`.
- El MCP `rea` tiene en su `env`: `GHIDRA_INSTALL_DIR` y `JAVA_HOME`
  (`~/.sdkman/candidates/java/21.0.5-amzn`). `rea doctor`: todo OK.
- **Ghidra no acepta Mach-O universales**: hay que analizar un slice extraído con
  `lipo <bin> -thin arm64 -output reverse-eng/thin/<Framework>`. Ya hay slices de
  10 frameworks en `thin/` (gitignored).
- Para el CLI, exporta `GHIDRA_INSTALL_DIR` y `JAVA_HOME` y usa `--provider ghidra`.

## Comandos REA utilizados (sin ejecutar la app)

| Paso | Comando | Evidence |
|:--|:--|:--|
| Inventario | `rea inspect-artifact <app>` | `ev_f38c31cddcaa367e…` (inventario `ev_633fec5c…`) |
| Grafo Apple | `rea project-apple-application-graph` | `ev_c40ebeee0aa25e17…` |
| Info.plist ×3 | `rea inspect-plist` | `ev_88c3942e…`, `ev_f547a1c6…`, `ev_fb093cc8…` |
| Firma | `rea inspect-signature` | `ev_895d9e52670d82de…` |
| Mach-O ×33 | `rea inspect-macho <framework binary>` | ver tabla abajo |

Todo se regenera con `tools/reproduce.sh`.

## Índice de Evidence

| Archivo | Evidence ID | Operación | SHA-256 sujeto |
|:--|:--|:--|:--|
| `01-inspect-artifact.json` | `ev_f38c31cddcaa367e…` | inspect_artifact | `0f738d832562` |
| `02-apple-application-graph.json` | `ev_c40ebeee0aa25e17…` | project_apple_application_graph | `0f738d832562` |
| `03-plist-healthmonitor.json` | `ev_f547a1c636afb032…` | inspect_plist | `df4eb2247352` |
| `03-plist-main.json` | `ev_88c3942ed83f7bff…` | inspect_plist | `f457a75d580d` |
| `03-plist-menu.json` | `ev_fb093cc8f3c9a911…` | inspect_plist | `46395a4ccba4` |
| `04-signature-main.json` | `ev_895d9e52670d82de…` | inspect_signature | `f457a75d580d` |
| `10-macho-ApplicationSelfRemoverService.json` | `ev_9ccefba7ba1666dd…` | inspect_macho | `2eed3b1e6764` |
| `10-macho-ApplicationsModuleDomain.json` | `ev_c6c19ab37f13b32c…` | inspect_macho | `fb4a2674893a` |
| `10-macho-ApplicationsService.json` | `ev_edb70ac3ff827fe3…` | inspect_macho | `5f069abb13e8` |
| `10-macho-ApplicationsTerminator.json` | `ev_a9003cad9336ac06…` | inspect_macho | `3accee69bb39` |
| `10-macho-CleaningCore.json` | `ev_356667e12b00847e…` | inspect_macho | `c456711f5830` |
| `10-macho-CloudStorageScanning.json` | `ev_47c2d18bae008cd6…` | inspect_macho | `579a0e46a5e2` |
| `10-macho-DatabaseKit.json` | `ev_6d4fea14401437fe…` | inspect_macho | `546e1a02aaeb` |
| `10-macho-DownloadsScanning.json` | `ev_15c6f8a473ab3647…` | inspect_macho | `1305c9496345` |
| `10-macho-FileManagerService.json` | `ev_f1d21a1321b5245a…` | inspect_macho | `bc405ffcba40` |
| `10-macho-JunkCleanupModule.json` | `ev_efa646f4316329f3…` | inspect_macho | `df1a60dfe1df` |
| `10-macho-LegacyScanningCore.json` | `ev_9211da1f66c11690…` | inspect_macho | `039c086b0eac` |
| `10-macho-LegacyScanningWrapperCore.json` | `ev_cbc3832675d39378…` | inspect_macho | `c274a6bc6c72` |
| `10-macho-MailJunkScanning.json` | `ev_d2c4e2c7eeff1242…` | inspect_macho | `6b7309e8632d` |
| `10-macho-MainExecutable.json` | `ev_15c4322e908c3da4…` | inspect_macho | `f457a75d580d` |
| `10-macho-NodesCore.json` | `ev_493306cb70399586…` | inspect_macho | `6cbfbf5812d7` |
| `10-macho-OrganizeScanning.json` | `ev_7311157cbb22b8d7…` | inspect_macho | `cc66f0415250` |
| `10-macho-PerformanceScanning.json` | `ev_906d7db4aeb8c1f0…` | inspect_macho | `20581c62ae23` |
| `10-macho-PerformanceService.json` | `ev_e3d4f89180c47ffe…` | inspect_macho | `5875eb2e8248` |
| `10-macho-PermissionsKit.json` | `ev_df09d704345c524d…` | inspect_macho | `8a89f81f8d19` |
| `10-macho-PrivacyScanning.json` | `ev_ac79d9008736addc…` | inspect_macho | `f1208d50c5a7` |
| `10-macho-PrivacyService.json` | `ev_b142990999ee17bc…` | inspect_macho | `a27c56942f37` |
| `10-macho-PrivilegedOperationsPerformerService.json` | `ev_ff07c55bb3d59958…` | inspect_macho | `84cea65a1d74` |
| `10-macho-PrivilegedRoutines.json` | `ev_5fe33c49ded41790…` | inspect_macho | `2e10c546cae3` |
| `10-macho-ScanningCore.json` | `ev_8c1fcb0ac1e9093c…` | inspect_macho | `3a05f0a98069` |
| `10-macho-SmartCareModule.json` | `ev_54f90d0662b49bf1…` | inspect_macho | `03a088391040` |
| `10-macho-SpaceLensModule.json` | `ev_b45c5b5e50523f44…` | inspect_macho | `155bd3cf7d82` |
| `10-macho-SpaceLensScanning.json` | `ev_c7b9c6f0f215f63e…` | inspect_macho | `24cc586de34b` |
| `10-macho-SystemJunkScanning.json` | `ev_0e69247bd4544e0d…` | inspect_macho | `d51c6049315b` |
| `10-macho-SystemPermissionsKit.json` | `ev_c3312ce6822270dc…` | inspect_macho | `c6c5f694c023` |
| `10-macho-TrashJunkScanning.json` | `ev_73c0da88dc6f213d…` | inspect_macho | `651c0d8fea28` |
| `10-macho-UninstallerScanning.json` | `ev_f1853b46a892858e…` | inspect_macho | `49bc4bb24b82` |
| `10-macho-UnusedDiskImagesScanning.json` | `ev_511d1b123f744bb9…` | inspect_macho | `4b2931d90174` |
| `10-macho-UpdaterScanning.json` | `ev_c9c9f1ad9aa33807…` | inspect_macho | `d1d15d42886f` |

## Cómo interpretar las conclusiones

Cada afirmación en los reportes está marcada como:

- **Observado**: aparece literalmente en la Evidence (nombre de símbolo,
  entitlement, ruta literal, plist).
- **Inferido**: deducción razonable a partir de nombres/firmas, sin haber visto
  el código. Puede estar mal.
- **Desconocido**: requiere decompilar o ejecutar.

Límites que conviene recordar:

- Los exports sólo muestran la API pública de cada framework; los tipos
  internos/privados y los símbolos stripped no aparecen.
- Un nombre de símbolo no prueba que la ruta de código se ejecute.
- Nada aquí se observó en ejecución.

## Ética y alcance

Se analizó para interoperabilidad y diseño de un producto propio. No se tocó
licencias/activación (`license_plan`, `ActivationService`) ni se descifró
`info.cmmkb`/`userInfo.cmmkb`. Las bases de reglas propietarias **no** deben
copiarse; cualquier implementación debe construir las suyas a partir de documentación
pública de macOS y observación propia.
