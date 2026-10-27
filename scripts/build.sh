#!/bin/zsh
# ReMON.app 조립(Folder Backup build.sh 방식). Xcode 없이 SwiftPM + 직접 번들링.
# CODESIGN_IDENTITY가 없으면 ad-hoc 서명, 있으면 Developer ID + hardened runtime + 보안 타임스탬프.
set -eu
cd "${0:A:h:h}"
build_root="$(mktemp -d /tmp/ReMON-build.XXXXXX)"
python3 scripts/build-manifest.py create "$build_root/BuildSourceManifest.json"
/usr/bin/swift build --scratch-path "$build_root" -c release --arch arm64 \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." --product ReMON
python3 scripts/build-manifest.py verify "$build_root/BuildSourceManifest.json"
bin_dir="$(/usr/bin/swift build --scratch-path "$build_root" -c release --arch arm64 --show-bin-path)"
app_dir="$PWD/dist/ReMON.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/ReMON" "$app_dir/Contents/MacOS/ReMON"
strip -S "$app_dir/Contents/MacOS/ReMON"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
[[ -f Resources/ReMON.icns ]] && cp Resources/ReMON.icns "$app_dir/Contents/Resources/ReMON.icns"
cp "$build_root/BuildSourceManifest.json" "$app_dir/Contents/Resources/"
[[ -f LICENSE ]] && cp LICENSE "$app_dir/Contents/Resources/"
identity="${CODESIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --identifier local.remon "$app_dir"
else
    codesign --force --sign "$identity" --identifier local.remon --options runtime --timestamp "$app_dir"
fi
codesign --verify --strict "$app_dir"
rm -rf "$build_root"
echo "$app_dir"
