#!/bin/zsh
# Build a product and wrap it in a minimal, ad-hoc signed .app bundle so macOS
# grants it its own Bluetooth permission.
#   scripts/bundle.sh PulseBar   -> build/PulseBar.app   (menu bar app)
#   scripts/bundle.sh pulsectl   -> build/PulseCtl.app   (CLI, run with scripts/pulsectl)
set -euo pipefail
cd "${0:A:h}/.."
product=${1:-PulseBar}
config=${CONFIG:-release}
version=$(cat VERSION)
swift build -c "$config" --product "$product" >&2
case $product in
  PulseBar) app=build/PulseBar.app; id=dev.local.pulsebar; ui=1 ;;
  pulsectl) app=build/PulseCtl.app; id=dev.local.pulsectl; ui=1 ;;
  *) echo "unknown product $product" >&2; exit 2 ;;
esac
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
cp ".build/$config/$product" "$app/Contents/MacOS/$product"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>${app:t:r}</string>
  <key>CFBundleExecutable</key><string>$product</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Controls your Sengled Pulse bulbs over Bluetooth.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >&2
echo "$app"
