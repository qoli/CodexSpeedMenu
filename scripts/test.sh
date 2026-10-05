#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -f Evidence/build-location.txt ]] || { mkdir -p Evidence; mktemp -d /tmp/CodexSpeedMenu-build.XXXXXX > Evidence/build-location.txt; }
scratch="$(cat Evidence/build-location.txt)"
export CLANG_MODULE_CACHE_PATH="$scratch/ModuleCache"
swift test --disable-sandbox --build-system native --scratch-path "$scratch" --cache-path "$scratch/cache" --config-path "$scratch/config" --security-path "$scratch/security" --manifest-cache local
