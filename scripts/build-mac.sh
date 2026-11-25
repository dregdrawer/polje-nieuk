#!/bin/zsh
# Builds and tests polje nieuk on macOS using only the Command Line Tools (no Xcode needed).
# Usage: scripts/build-mac.sh [run|test]
set -euo pipefail
cd "$(dirname "$0")/.."

# Pick an SDK the installed compiler understands (newest first, skipping ones built by a newer Swift).
SDK=""
for s in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
  # (a SwiftUI @State, not just print: a newer SDK can lack the SwiftUI macro plugin the installed tools need)
  if printf 'import SwiftUI\nstruct V: View { @State var x = 0; var body: some View { Text("") } }\n' | swiftc -sdk "$s" -typecheck - >/dev/null 2>&1; then SDK="$s"; break; fi
done
[[ -z "$SDK" ]] && { echo "No usable macOS SDK found"; exit 1; }
echo "Using SDK: $SDK"

OUT=.build/manual
mkdir -p $OUT

# Universal: everything is compiled for Apple Silicon (arm64) and Intel (x86_64), then joined with lipo.
# Set ARCHS=arm64 for a quicker Apple-Silicon-only build while developing.
ARCHS=(${=ARCHS:-arm64 x86_64})
MI=Vendor/mutable
MISRC=( $(find $MI/clouds $MI/rings $MI/plaits $MI/elements $MI/warps $MI/tides2 $MI/marbles $MI/stages $MI/braids $MI/beads -name "*.cc") $MI/stmlib/dsp/units.cc $MI/stmlib/dsp/atan.cc $MI/stmlib/utils/random.cc $MI/bridge/mi_bridge.cpp )
BINS=()
for ARCH in "${ARCHS[@]}"; do
  A=$OUT/$ARCH
  mkdir -p $A/mi
  TARGET=$ARCH-apple-macos15.0
  FLAGS=(-sdk "$SDK" -swift-version 5 -O -target $TARGET -I $A -L $A -I $MI/bridge/include -I Vendor/vst3/bridge/include)

  # Eurorack DSP (C++): compile changed files only, then archive.
  for f in "${MISRC[@]}"; do
    o=$A/mi/$(echo ${f#$MI/} | tr '/' '_').o
    if [[ ! -f $o || $f -nt $o || $MI/bridge/include/mi_bridge.h -nt $o ]]; then
      clang++ -isysroot "$SDK" -target $TARGET -std=gnu++14 -O2 -DTEST -I$MI -I$MI/bridge/include -w -c $f -o $o
    fi
  done
  rm -f $A/libMutableDSP.a
  ar rcs $A/libMutableDSP.a $A/mi/*.o
  # the VST3 host (C++) for the plugin box
  mkdir -p $A/vst3
  for f in Vendor/vst3/bridge/vst3host.cpp Vendor/vst3/pluginterfaces/base/funknown.cpp; do
    o=$A/vst3/$(basename $f .cpp).o
    if [[ ! -f $o || $f -nt $o || Vendor/vst3/bridge/include/pn_vst3.h -nt $o ]]; then
      clang++ -isysroot "$SDK" -target $TARGET -std=gnu++14 -O2 -IVendor/vst3 -w -c $f -o $o
    fi
  done
  rm -f $A/libPluginBridge.a
  ar rcs $A/libPluginBridge.a $A/vst3/*.o

  # the audio engine: whole-module optimised, and without the runtime exclusivity checks Swift otherwise
  # runs on every per-sample access to a module's stored arrays (only the audio thread touches them)
  swiftc "${FLAGS[@]}" -wmo -enforce-exclusivity=unchecked -parse-as-library -module-name PoljeNieukCore -emit-module -emit-module-path $A/PoljeNieukCore.swiftmodule \
    -emit-library -static -o $A/libPoljeNieukCore.a Sources/PoljeNieukCore/*.swift Sources/PoljeNieukCore/Modules/*.swift
  swiftc "${FLAGS[@]}" -parse-as-library -module-name PoljeNieukUI -emit-module -emit-module-path $A/PoljeNieukUI.swiftmodule \
    -emit-library -static -o $A/libPoljeNieukUI.a Sources/PoljeNieukUI/*.swift
  swiftc "${FLAGS[@]}" -parse-as-library -lPoljeNieukCore -lPoljeNieukUI -lMutableDSP -lPluginBridge -lc++ Sources/PoljeNieukMac/*.swift -o "$A/polje nieuk"
  BINS+=("$A/polje nieuk")
  # the self-test runs on this Mac: build it for this Mac's own architecture
  if [[ $ARCH == $(uname -m) ]]; then
    swiftc "${FLAGS[@]}" -lPoljeNieukCore -lPoljeNieukUI -lMutableDSP -lPluginBridge -lc++ Sources/SelfTest/main.swift -o $OUT/selftest
  fi
done
lipo -create "${BINS[@]}" -output "$OUT/polje nieuk"
echo "Architectures: $(lipo -archs "$OUT/polje nieuk")"
# Wrap in a minimal .app bundle so macOS can ask for audio-input permission.
APP="$OUT/polje nieuk.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/polje nieuk" "$APP/Contents/MacOS/polje nieuk"
# App icon (regenerated from scripts/make-icon.swift if missing)
if [[ ! -d ".build/polje nieuk.iconset" ]]; then
  mkdir -p .build/icontool
  swiftc -sdk "$SDK" -target arm64-apple-macos15.0 scripts/make-icon.swift -o .build/icontool/make-icon
  .build/icontool/make-icon "$PWD"
fi
iconutil -c icns ".build/polje nieuk.iconset" -o "$APP/Contents/Resources/polje nieuk.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.grzegorzdalmata.poljenieuk.mac</string>
  <key>CFBundleName</key><string>polje nieuk</string>
  <key>CFBundleDisplayName</key><string>polje nieuk</string>
  <key>CFBundleExecutable</key><string>polje nieuk</string>
  <key>CFBundleIconFile</key><string>polje nieuk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.8</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>polje nieuk processes audio from your modular through your audio interface.</string>
</dict></plist>
PLIST
# Sign with your Apple Development certificate when there is one: macOS then recognises every rebuild as
# the same app and remembers the microphone permission (ad-hoc signing makes it ask again after each build).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')
SIGNED=adhoc
if [[ -n "$IDENTITY" ]] && perl -e 'alarm 20; exec @ARGV' codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
  SIGNED="$IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Signed: $SIGNED"
echo "Built $APP and $OUT/selftest"

case "${1:-}" in
  test) $OUT/selftest ;;
  run)  open "$APP" ;;
esac
