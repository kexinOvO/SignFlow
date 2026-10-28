#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output="$PWD/build/DeviceExpiryVerification"
registry="$HOME/Documents/Codex/monitor/bin/aar"
rebuild="[\"/bin/zsh\",\"$PWD/Scripts/verify-device-expiry.sh\"]"
finalize() {
    local verification_exit=$?
    local registry_failed=0
    for directory in SwiftPM DebugDerivedData; do
        if [[ -e "$output/$directory" ]]; then
            "$registry" register --path "$output/$directory" --project "$PWD" --type BUILD --regenerable --source 'SignFlow device expiry verification build' --argv-json "$rebuild" --accept-modified --json || registry_failed=1
        fi
    done
    for report in tests.log build.log; do
        if [[ -e "$output/$report" ]]; then
            "$registry" register --path "$output/$report" --project "$PWD" --type GENERATED --regenerable --safe-to-delete --source 'SignFlow redacted device expiry verification report' --argv-json "$rebuild" --accept-modified --json || registry_failed=1
        fi
    done
    if (( registry_failed )); then exit 1; fi
    exit "$verification_exit"
}
for directory in SwiftPM DebugDerivedData; do
    if [[ ! -e "$output/$directory" ]]; then
        "$registry" register --path "$output/$directory" --project "$PWD" --type BUILD --regenerable --source 'SignFlow device expiry verification build' --argv-json "$rebuild" --json
    fi
done
for report in tests.log build.log; do
    if [[ ! -e "$output/$report" ]]; then
        "$registry" register --path "$output/$report" --project "$PWD" --type GENERATED --regenerable --safe-to-delete --source 'SignFlow redacted device expiry verification report' --argv-json "$rebuild" --json
    fi
done
trap finalize EXIT
mkdir -p "$output"
swift test --scratch-path "$output/SwiftPM" 2>&1 | python3 Scripts/RedactLog.py | tee "$output/tests.log"
xcodebuild -project SignFlow.xcodeproj -scheme SignFlow -configuration Debug -derivedDataPath "$output/DebugDerivedData" build 2>&1 | python3 Scripts/RedactLog.py | tee "$output/build.log"
codesign --verify --deep --strict --verbose=2 "$output/DebugDerivedData/Build/Products/Debug/SignFlow.app"
