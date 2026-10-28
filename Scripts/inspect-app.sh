#!/bin/zsh
set -euo pipefail
if (( $# != 1 )); then
    print -u2 'Usage: /bin/zsh Scripts/inspect-app.sh /path/to/App.app'
    exit 64
fi
signature_app_path="${1:A}"
signature_script_path="${0:A}"
cd "${0:A:h:h}"
mkdir -p build/Verification
swift run --scratch-path build/SwiftPM SignFlowProbe --inspect-app "$signature_app_path" 2>&1 | python3 Scripts/RedactLog.py | tee build/Verification/signature-inspection.log
signature_rebuild_argv="$(python3 -c 'import json,sys; print(json.dumps(["/bin/zsh", *sys.argv[1:]]))' "$signature_script_path" "$signature_app_path")"
aar register --path "$PWD/build/Verification/signature-inspection.log" --project "$PWD" --type GENERATED --regenerable --safe-to-delete --source 'SignFlow read-only signature inspection report; requires the referenced existing app' --argv-json "$signature_rebuild_argv" --accept-modified --json
