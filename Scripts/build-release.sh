#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
xcodebuild -project SignFlow.xcodeproj -scheme SignFlow -configuration Release -derivedDataPath build/ReleaseDerivedData build 2>&1 | python3 Scripts/RedactLog.py | tee build/release-build.log
codesign --verify --deep --strict --verbose=2 build/ReleaseDerivedData/Build/Products/Release/SignFlow.app
aar register --path "$PWD/build/ReleaseDerivedData" --project "$PWD" --type BUILD --regenerable --safe-to-delete --source 'SignFlow Release build outputs' --argv-json "[\"/bin/zsh\",\"$PWD/Scripts/build-release.sh\"]" --accept-modified --json
