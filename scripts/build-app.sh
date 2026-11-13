#!/bin/bash
# Builds build/OwonScope.app (release, self-contained libusb, ad-hoc signed).
#
#   scripts/build-app.sh                       # app only
#   scripts/build-app.sh --firmware <dir>      # also bundle VDS1022_FPGAV*.bin for local use
#   scripts/build-app.sh --install             # copy to /Applications afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

FIRMWARE=""
INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --firmware) FIRMWARE="$2"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

swift build -c release --product OwonScope
BIN="$(swift build -c release --show-bin-path)/OwonScope"

APP=build/OwonScope.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/OwonScope"

# Bundle libusb so the app runs without Homebrew.
LIBUSB=$(otool -L "$APP/Contents/MacOS/OwonScope" | awk '/libusb/ {print $1}')
if [ -n "$LIBUSB" ]; then
  REAL=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$LIBUSB")
  cp "$REAL" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
  chmod u+w "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
  install_name_tool -id @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
  install_name_tool -change "$LIBUSB" @rpath/libusb-1.0.0.dylib "$APP/Contents/MacOS/OwonScope"
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/OwonScope" 2>/dev/null || true
fi

if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

if [ -n "$FIRMWARE" ]; then
  mkdir -p "$APP/Contents/Resources/Firmware"
  cp "$FIRMWARE"/VDS1022_FPGAV*.bin "$APP/Contents/Resources/Firmware/"
fi

VERSION=$(git describe --tags --always 2>/dev/null || echo "0.1")
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OwonScope</string>
  <key>CFBundleDisplayName</key><string>OwonScope</string>
  <key>CFBundleIdentifier</key><string>io.github.owonscope</string>
  <key>CFBundleExecutable</key><string>OwonScope</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  rm -rf /Applications/OwonScope.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/OwonScope.app"
fi
