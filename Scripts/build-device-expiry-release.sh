#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output="$PWD/build/DeviceExpiryRelease"
registry="$HOME/Documents/Codex/monitor/bin/aar"
rebuild="[\"/bin/zsh\",\"$PWD/Scripts/build-device-expiry-release.sh\"]"
register_outputs() {
    local accept=$1
    local flags=()
    if [[ "$accept" == yes ]]; then flags+=(--accept-modified); fi
    "$registry" register --path "$output/DerivedData" --project "$PWD" --type BUILD --regenerable --source 'SignFlow device expiry Release build' --argv-json "$rebuild" "${flags[@]}" --json || return 1
    "$registry" register --path "$output/DerivedData/Build/Products/Release/SignFlow.app" --project "$PWD" --type DISTRIBUTION --regenerable --source 'SignFlow device expiry Release application' --argv-json "$rebuild" "${flags[@]}" --json || return 1
    "$registry" register --path "$output/build.log" --project "$PWD" --type GENERATED --regenerable --safe-to-delete --source 'SignFlow redacted device expiry Release build report' --argv-json "$rebuild" "${flags[@]}" --json || return 1
}
finalize() {
    local build_exit=$?
    if ! register_outputs yes; then exit 1; fi
    exit "$build_exit"
}
register_outputs no
trap finalize EXIT
mkdir -p "$output"
xcodebuild -project SignFlow.xcodeproj -scheme SignFlow -configuration Release -derivedDataPath "$output/DerivedData" build 2>&1 | python3 Scripts/RedactLog.py | tee "$output/build.log"
codesign --verify --deep --strict --verbose=2 "$output/DerivedData/Build/Products/Release/SignFlow.app"
