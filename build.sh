#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
build_only=false
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == --build-only ]]; then
    build_only=true
  else
    printf '%s\n' "Usage: ./build.sh [--build-only]" >&2
    exit 2
  fi
fi
mkdir -p build/GlassDock.app/Contents/MacOS build/GlassDock.app/Contents/Resources
xcrun swiftc -swift-version 6 -O -target arm64-apple-macos26.0 \
  main.swift WindowOrder.swift AppUpdater.swift -o build/GlassDock.app/Contents/MacOS/GlassDock \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit
cat > build/GlassDock.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>GlassDock</string>
  <key>CFBundleIdentifier</key><string>local.glassdock.app</string>
  <key>CFBundleName</key><string>GlassDock</string>
  <key>CFBundleDisplayName</key><string>GlassDock</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>GlassDock показывает содержимое ваших окон при наведении на значок Dock. Изображения остаются только в памяти.</string>
</dict></plist>
PLIST
xcrun swift Icon.swift
iconutil -c icns build/AppIcon.iconset -o build/GlassDock.app/Contents/Resources/AppIcon.icns
codesign --force --sign - --identifier local.glassdock.app \
  --requirements '=designated => identifier "local.glassdock.app"' build/GlassDock.app
codesign --verify --deep --strict build/GlassDock.app
build/GlassDock.app/Contents/MacOS/GlassDock --self-test
if [[ "$build_only" == true ]]; then
  printf '%s\n' "Built: $PWD/build/GlassDock.app (not installed)"
  exit 0
fi
destination=/Applications/GlassDock.app
if [[ -e "$destination" ]]; then
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  if [[ "$installed_id" != local.glassdock.app ]]; then
    printf '%s\n' "Refusing to overwrite an unrelated app: $destination" >&2
    exit 1
  fi
fi
ditto build/GlassDock.app "$destination"
printf '%s\n' "Installed: $destination"
