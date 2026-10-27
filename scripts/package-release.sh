#!/bin/zsh
# 배포 포장(Folder Backup 절차 계승): Developer ID 서명된 dist/ReMON.app →
# ① 앱 공증(notarytool) → staple → Gatekeeper 확인 ② DMG(드래그 설치) 생성·서명 → DMG 공증 → staple → 확인 → SHA-256.
# staple 뒤에는 재빌드하지 않는다(다른 실행 파일이 된다). 비밀값은 출력·커밋하지 않는다(키체인 프로필만 사용).
set -eu
cd "${0:A:h:h}"
app="dist/ReMON.app"
identity="${CODESIGN_IDENTITY:?CODESIGN_IDENTITY(SHA-1)를 지정하세요}"
profile="${NOTARY_PROFILE:-storearc-notary}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
out="dist/release-$version-$build"
rm -rf "$out"
mkdir -p "$out"

codesign --verify --strict "$app"
codesign -dvv "$app" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "Developer ID 서명이 아닙니다"; exit 1; }
python3 scripts/build-manifest.py verify "$app/Contents/Resources/BuildSourceManifest.json"

echo "== 1/2 앱 공증"
ditto -c -k --keepParent "$app" "$out/ReMON-$version-notarize.zip"
xcrun notarytool submit "$out/ReMON-$version-notarize.zip" --keychain-profile "$profile" --wait --output-format json > "$out/notary-app.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("app notarization:", d.get("status"), d.get("id")); sys.exit(0 if d.get("status")=="Accepted" else 1)' "$out/notary-app.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict "$app"
spctl --assess --type execute --verbose=4 "$app" 2>&1 | tee "$out/spctl-app.txt"
rm -f "$out/ReMON-$version-notarize.zip"

echo "== 2/2 DMG"
staging="$(mktemp -d /tmp/ReMON-dmg.XXXXXX)"
ditto "$app" "$staging/ReMON.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "ReMON $version" -srcfolder "$staging" -ov -format UDZO "$out/ReMON-$version.dmg" >/dev/null
rm -rf "$staging"
codesign --force --sign "$identity" --timestamp "$out/ReMON-$version.dmg"
xcrun notarytool submit "$out/ReMON-$version.dmg" --keychain-profile "$profile" --wait --output-format json > "$out/notary-dmg.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("dmg notarization:", d.get("status"), d.get("id")); sys.exit(0 if d.get("status")=="Accepted" else 1)' "$out/notary-dmg.json"
xcrun stapler staple "$out/ReMON-$version.dmg"
xcrun stapler validate "$out/ReMON-$version.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$out/ReMON-$version.dmg" 2>&1 | tee "$out/spctl-dmg.txt"
(cd "$out" && shasum -a 256 "ReMON-$version.dmg" > SHA256SUMS)
cat "$out/SHA256SUMS"
echo "release: $out"
