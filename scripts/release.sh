#!/bin/zsh
# Uses the existing Xcode account for cloud Developer ID signing and a Keychain
# profile for notarization. No credentials are embedded in the repository.
set -euo pipefail
cd "${0:A:h:h}"
team="${DEVELOPMENT_TEAM:-WQY45CL427}"
profile="${NOTARY_PROFILE:-SwiftChat-Notary}"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw App/Info.plist)
mkdir -p Evidence dist
scripts/make-icon.sh
# The generated project is included; XcodeGen is needed only after editing project.yml.
archive="$PWD/dist/CodexSpeedMenu-$version.xcarchive"
exported="$PWD/dist/Export-$version"
app="$exported/Codex Speed.app"
xcodebuild -project CodexSpeedMenu.xcodeproj -scheme CodexSpeedMenu \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$PWD/Evidence/DerivedData" -archivePath "$archive" \
  "DEVELOPMENT_TEAM=$team" -allowProvisioningUpdates archive \
  2>&1 | tee Evidence/archive.log
cat > Evidence/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$team</string>
<key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$exported" \
  -exportOptionsPlist Evidence/ExportOptions.plist -allowProvisioningUpdates \
  2>&1 | tee Evidence/export.log
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2> Evidence/signature.txt
ditto -c -k --norsrc --keepParent "$app" dist/notary-submission.zip
xcrun notarytool submit dist/notary-submission.zip --keychain-profile "$profile" \
  --output-format json > Evidence/notary-submission.json
submission=$(/usr/bin/plutil -extract id raw Evidence/notary-submission.json)
xcrun notarytool wait "$submission" --keychain-profile "$profile" \
  --output-format json > Evidence/notary-result.json
xcrun notarytool log "$submission" --keychain-profile "$profile" Evidence/notary-log.json
notary_status=$(/usr/bin/plutil -extract status raw Evidence/notary-result.json)
[[ "$notary_status" == Accepted ]] || { print -u2 "Notarization: $notary_status; see Evidence/notary-log.json"; exit 1; }
xcrun stapler staple "$app" 2>&1 | tee Evidence/staple.log
xcrun stapler validate "$app" 2>&1 | tee Evidence/staple-validation.log
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=4 "$app" 2>&1 | tee Evidence/gatekeeper.log
ditto --norsrc "$app" "$PWD/dist/Codex Speed.app"
ditto -c -k --norsrc --keepParent "$app" "$PWD/dist/Codex-Speed-$version.zip"
shasum -a 256 "dist/Codex-Speed-$version.zip" > Evidence/release-sha256.txt
print "Notarized release: $PWD/dist/Codex-Speed-$version.zip"
