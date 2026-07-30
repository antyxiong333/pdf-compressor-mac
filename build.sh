#!/bin/bash
# Build PDFCompressor.app — a self-contained, unsigned macOS app.
set -e
cd "$(dirname "$0")"

APP="PDF 压缩.app"
BUNDLE_ID="local.pdfcompressor"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
BIN="pdfcompressor"

echo "▸ Cleaning old build…"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "▸ Compiling (this may take ~30s)…"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework Quartz -framework PDFKit -framework AppKit \
  -o "$MACOS/$BIN" \
  Sources/main.swift

echo "▸ Adding app icon…"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$RES/AppIcon.icns"; fi

echo "▸ Writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PDF 压缩</string>
    <key>CFBundleDisplayName</key><string>PDF 压缩</string>
    <key>CFBundleExecutable</key><string>$BIN</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc code signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

echo "✅ Done: $(pwd)/$APP"
