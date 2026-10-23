#!/usr/bin/env bash
# droidlink.app (Apple Silicon + Intel 공용)을 만들고 배포용 zip으로 묶는다.
# scrcpy 공식 macOS 빌드에서 adb와 scrcpy-server만 꺼내 앱 안에 넣는다 (scrcpy 창 앱은 쓰지 않음). Homebrew 없이 동작한다.
# 사용: ./build-app.sh [버전]   → droidlink.app, droidlink-macos.zip
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-1.0.0}"
scrcpy_version=5.0.1  # edge.swift의 scrcpyVersion과 같아야 한다
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
mkdir -p droidlink.app/Contents/MacOS droidlink.app/Contents/Resources/scrcpy
lipo -create "$tmp/edge-arm64" "$tmp/edge-x86_64" -output droidlink.app/Contents/MacOS/droidlink
tools=droidlink.app/Contents/Resources/scrcpy
cp "$cache/aarch64/adb" "$cache/aarch64/scrcpy-server" "$tools/"  # adb는 이미 universal, 서버는 두 빌드가 같다
cp "$cache/aarch64/LICENSE" "$tools/LICENSE-scrcpy"
codesign --force --sign - "$tools/adb"
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
