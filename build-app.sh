#!/usr/bin/env bash
# droidlink.app (Apple Silicon + Intel 공용)을 만들고 배포용 zip으로 묶는다.
# 사용: ./build-app.sh [버전]   → droidlink.app, droidlink-macos.zip
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-1.0.0}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for arch in arm64 x86_64; do
  swiftc -suppress-warnings -target "$arch-apple-macos13" edge.swift -o "$tmp/edge-$arch"
done

rm -rf droidlink.app droidlink-macos.zip
mkdir -p droidlink.app/Contents/MacOS
lipo -create "$tmp/edge-arm64" "$tmp/edge-x86_64" -output droidlink.app/Contents/MacOS/droidlink
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
