#!/usr/bin/env bash
# Builds "Telegram-Granola Autorecord.app".
#
#   scripts/build-app.sh [--sign IDENTITY] [--arch universal|native] [--output DIR]
#
# --sign    codesign identity. "-" (the default) signs ad hoc for local testing.
#           A "Developer ID Application: ..." identity also enables the hardened runtime and a secure timestamp.
# --arch    "universal" (default, needs full Xcode) or "native".
# --output  directory for the app bundle, default .build/app.
set -euo pipefail

SIGN="-"
ARCH="universal"
OUTPUT=".build/app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

product_value() {
  sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" Sources/AutorecordCore/Product.swift | head -1
}
NAME="$(product_value name)"
BUNDLE_ID="$(product_value bundleID)"
COMMAND="$(product_value command)"
VERSION="$(product_value version)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
MIN_MACOS="14.4"

echo "==> Building $NAME $VERSION ($BUILD_NUMBER), $ARCH"
if [[ "$ARCH" == "universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BINARY=".build/apple/Products/Release/$COMMAND"
else
  swift build -c release
  BINARY="$(swift build -c release --show-bin-path)/$COMMAND"
fi

APP="$OUTPUT/$NAME.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchAgents"
cp "$BINARY" "$CONTENTS/MacOS/$COMMAND"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$NAME</string>
  <key>CFBundleExecutable</key>
  <string>$COMMAND</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>MIT License. Not affiliated with Telegram or Granola.</string>
</dict>
</plist>
PLIST

cat > "$CONTENTS/Library/LaunchAgents/$BUNDLE_ID.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BUNDLE_ID.agent</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/$COMMAND</string>
  <key>ProgramArguments</key>
  <array>
    <string>$COMMAND</string>
    <string>agent</string>
  </array>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$BUNDLE_ID</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS/Info.plist" "$CONTENTS/Library/LaunchAgents/$BUNDLE_ID.agent.plist" >/dev/null

echo "==> Signing with identity: $SIGN"
if [[ "$SIGN" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "==> $APP"
