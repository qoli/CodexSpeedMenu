#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p Evidence dist
scripts/make-icon.sh
if [[ ! -f Evidence/build-location.txt ]]; then
  mktemp -d /tmp/CodexSpeedMenu-build.XXXXXX > Evidence/build-location.txt
fi
scratch="$(cat Evidence/build-location.txt)"
export CLANG_MODULE_CACHE_PATH="$scratch/ModuleCache"
swift build --disable-sandbox --build-system native -c release --scratch-path "$scratch" --cache-path "$scratch/cache" --config-path "$scratch/config" --security-path "$scratch/security" --manifest-cache local
destination="$PWD/dist/Codex Speed.app"
app="$scratch/Codex Speed.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Fixtures/upstream.jsonl "$app/Contents/Resources/upstream.jsonl"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp Assets/AppIcon.icns "$app/Contents/Resources/"
cp "$scratch/release/CodexSpeedMenu" "$app/Contents/MacOS/CodexSpeedMenu"
cp App/Info.plist "$app/Contents/Info.plist"
xattr -cr "$app"
codesign --force --options runtime --sign - "$app"
ditto --norsrc "$app" "$destination"
xattr -d com.apple.FinderInfo "$destination" 2>/dev/null || true
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$PWD/dist/Codex-Speed.zip"
printf '%s\n' "$app" "$PWD/dist/Codex-Speed.zip"
