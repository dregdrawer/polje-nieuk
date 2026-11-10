#!/bin/zsh
# Builds polje nieuk, signs it with your Personal Team, installs it on the connected iPad and opens it.
# Re-run every 7 days (free Apple ID signing expires) or after changes.
# Usage: scripts/install-ipad.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEAM=25PG878U8X
BUNDLE=com.grzegorzdalmata.poljenieuk

# First physical iPad that's connected
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPad/ && /connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i }' | head -1)
if [[ -z "$DEVICE" ]]; then
  echo "No iPad found. Plug it in with a data cable, unlock it, and tap Trust."; exit 1
fi
echo "iPad: $DEVICE"

xcodegen generate >/dev/null 2>&1 || true
xcodebuild -project "polje nieuk.xcodeproj" -scheme "polje nieuk" -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath .build/xcode \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic build > .build/ipad-build.log 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" .build/ipad-build.log || true
# never install a stale app from an earlier build
grep -q "BUILD SUCCEEDED" .build/ipad-build.log || { echo "Build failed — nothing installed (see .build/ipad-build.log)."; exit 1; }

APP=".build/xcode/Build/Products/Release-iphoneos/polje nieuk.app"
[[ -d "$APP" ]] || { echo "Build failed."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null && echo "Installed."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null 2>&1 && echo "Launched." \
  || echo "Installed — open it on the iPad (first time: Settings → General → VPN & Device Management → trust your Apple ID)."
