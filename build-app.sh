#!/usr/bin/env bash
# droidlink.app (Apple Silicon + Intel 공용)을 만들고 배포용 zip으로 묶는다.
# scrcpy 공식 macOS 빌드(adb·scrcpy-server 포함)를 받아 앱 안에 넣으므로 Homebrew 없이 동작한다.
# 사용: ./build-app.sh [버전]   → droidlink.app, droidlink-macos.zip
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-1.0.0}"
scrcpy_version=5.0.1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for arch in arm64 x86_64; do
  swiftc -suppress-warnings -target "$arch-apple-macos13" edge.swift -o "$tmp/edge-$arch"
done

# scrcpy 공식 릴리스를 받아 체크섬을 확인한다 (.build에 캐시)
cache=".build/scrcpy-$scrcpy_version"
if [ ! -d "$cache/x86_64" ]; then
  rm -rf "$cache"; mkdir -p "$cache"
  base="https://github.com/Genymobile/scrcpy/releases/download/v$scrcpy_version"
  curl -fsSL "$base/SHA256SUMS.txt" -o "$cache/SHA256SUMS.txt"
  for a in aarch64 x86_64; do
    curl -fsSL "$base/scrcpy-macos-$a-v$scrcpy_version.tar.gz" -o "$cache/scrcpy-macos-$a-v$scrcpy_version.tar.gz"
  done
  (cd "$cache" && grep macos SHA256SUMS.txt | shasum -a 256 -c)
  for a in aarch64 x86_64; do
    mkdir "$cache/$a" && tar -xzf "$cache/scrcpy-macos-$a-v$scrcpy_version.tar.gz" -C "$cache/$a" --strip-components 1
  done
fi

rm -rf droidlink.app droidlink-macos.zip
helper=droidlink.app/Contents/Helpers/droidlink-input.app/Contents
mkdir -p droidlink.app/Contents/MacOS droidlink.app/Contents/Resources/scrcpy "$helper/MacOS"
lipo -create "$tmp/edge-arm64" "$tmp/edge-x86_64" -output droidlink.app/Contents/MacOS/droidlink
tools=droidlink.app/Contents/Resources/scrcpy
cp "$cache/aarch64/adb" "$cache/aarch64/scrcpy-server" "$tools/"  # adb는 이미 universal, 서버는 두 빌드가 같다
cp "$cache/aarch64/LICENSE" "$tools/LICENSE-scrcpy"
# scrcpy는 작은 도우미 앱으로 감싸서 Dock에 "droidlink 입력"으로 보이게 한다 (scrcpy가 쓰는 SDL이 Dock 숨김을 막음)
lipo -create "$cache/aarch64/scrcpy" "$cache/x86_64/scrcpy" -output "$helper/MacOS/scrcpy"
cat > "$helper/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>droidlink 입력</string>
  <key>CFBundleIdentifier</key><string>com.ttekkeollug.droidlink.input</string>
  <key>CFBundleExecutable</key><string>scrcpy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$tools/adb" "$helper/.."
cat > droidlink.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>droidlink</string>
  <key>CFBundleDisplayName</key><string>droidlink</string>
  <key>CFBundleIdentifier</key><string>com.ttekkeollug.droidlink</string>
  <key>CFBundleExecutable</key><string>droidlink</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# ponytail: 애드혹 서명만 한다. 개발자 ID 서명·공증을 하면 처음 열 때 경고가 사라진다.
codesign --force --sign - droidlink.app
ditto -c -k --keepParent droidlink.app droidlink-macos.zip
echo "droidlink.app, droidlink-macos.zip ($version)"
