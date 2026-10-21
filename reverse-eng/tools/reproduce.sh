#!/bin/zsh
# Regenera toda la evidencia de reverse-eng/ desde el bundle instalado.
# Requiere: Node 22.22.1 vía nvm (REA no soporta Node 23), rea-agents@6.5.0,
# Xcode Command Line Tools (swift-demangle). No ejecuta CleanMyMac.
set -euo pipefail
export PATH="$HOME/.nvm/versions/node/v22.22.1/bin:$PATH"
command -v rea >/dev/null || npm install -g rea-agents@6.5.0
HERE=${0:A:h:h}
APP=/Applications/CleanMyMac_5_MAS.app
FW=$APP/Contents/Frameworks
E=$HERE/evidence; mkdir -p $E $HERE/symbols $HERE/strings
TMP=$(mktemp -d)

rea inspect-artifact $APP --format json > $E/01-inspect-artifact.json
python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));json.dump({'inventory_evidence':[d['normalized_result']['substeps'][0]['evidence']]},open(sys.argv[2],'w'))" $E/01-inspect-artifact.json $TMP/apple-in.json
rea project-apple-application-graph $TMP/apple-in.json --format json > $E/02-apple-application-graph.json
rea inspect-plist $APP --format json > $E/03-plist-main.json
rea inspect-plist $APP/Contents/Library/LoginItems/CleanMyMac_5_MAS_HealthMonitor.app --format json > $E/03-plist-healthmonitor.json
rea inspect-plist $APP/Contents/Library/LoginItems/CleanMyMac_5_MAS_Menu.app --format json > $E/03-plist-menu.json
rea inspect-signature $APP --format json > $E/04-signature-main.json
rea inspect-macho $APP/Contents/MacOS/CleanMyMac_5_MAS --format json > $E/10-macho-MainExecutable.json

MODULES=(SystemJunkScanning TrashJunkScanning DownloadsScanning UninstallerScanning SpaceLensScanning
  PrivacyScanning MailJunkScanning UpdaterScanning UnusedDiskImagesScanning PerformanceScanning CleaningCore
  ScanningCore LegacyScanningCore LegacyScanningWrapperCore OrganizeScanning CloudStorageScanning
  JunkCleanupModule FileManagerService PrivilegedRoutines PrivilegedOperationsPerformerService
  ApplicationsTerminator ApplicationsService ApplicationsModuleDomain SmartCareModule NodesCore
  PermissionsKit SystemPermissionsKit SpaceLensModule PerformanceService PrivacyService
  ApplicationSelfRemoverService DatabaseKit)
for m in $MODULES; do
  rea inspect-macho $FW/$m.framework/$m --format json > $E/10-macho-$m.json
  strings -a -n 4 $FW/$m.framework/$m | grep -E '(^|[^A-Za-z])(~/|/Library|/private|/var/|/System|/Users|/usr/|/tmp|/Applications|Library/|\.app\b|\.plist|\.db\b|\.sqlite|Caches|Logs|com\.apple\.)' | sort -u > $HERE/strings/$m.paths.txt || true
done
python3 -I $HERE/tools/demangle_exports.py $E $HERE/symbols
rm -rf $TMP
echo "OK: $(ls $E | wc -l) evidence files"
