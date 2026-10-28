#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
swift run --scratch-path build/SwiftPM SignFlowProbe "$@" --devices 2>&1 | python3 Scripts/RedactLog.py | tee build/project-probe.log
swift run --scratch-path build/SwiftPM SignFlowProbe --signing 2>&1 | python3 Scripts/RedactLog.py | tee build/signing-probe.log
