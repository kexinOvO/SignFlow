#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/Verification
swift test --scratch-path build/SwiftPM 2>&1 | python3 Scripts/RedactLog.py | tee build/Verification/tests.log
xcodebuild -project SignFlow.xcodeproj -scheme SignFlow -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | python3 Scripts/RedactLog.py | tee build/Verification/build.log
codesign --verify --deep --strict --verbose=2 build/DerivedData/Build/Products/Debug/SignFlow.app
aar register --path "$PWD/build/DerivedData" --project "$PWD" --type BUILD --regenerable --safe-to-delete --source 'SignFlow Xcode build outputs' --argv-json "[\"/bin/zsh\",\"$PWD/Scripts/verify.sh\"]" --accept-modified --json
aar register --path "$PWD/build/SwiftPM" --project "$PWD" --type BUILD --regenerable --safe-to-delete --source 'SignFlow core SwiftPM outputs' --argv-json "[\"swift\",\"test\",\"--package-path\",\"$PWD\",\"--scratch-path\",\"$PWD/build/SwiftPM\"]" --accept-modified --json
aar register --path "$PWD/build/Verification" --project "$PWD" --type GENERATED --regenerable --safe-to-delete --source 'SignFlow verification reports' --argv-json "[\"/bin/zsh\",\"$PWD/Scripts/verify.sh\"]" --accept-modified --json
