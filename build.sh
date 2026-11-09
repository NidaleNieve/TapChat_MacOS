#!/bin/bash
# Builds TapChat.app and installs it to /Applications (quits a running copy first).
set -euo pipefail
cd "$(dirname "$0")"

# Build output lives outside the project: the project is in iCloud-synced
# Documents, and syncing a 200 MB build folder stalls iCloud Drive (and with it
# the compiler).
SCRATCH="$HOME/Library/Caches/TapChat-build"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/TapChat"
APP="/Applications/TapChat.app"
# Earlier names of this app, replaced by it.
OLD="$HOME/Applications/QuickChat.app"
OLDER="/Applications/QuickChat.app"
STAGE="$(mktemp -d)/TapChat.app"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$BIN" "$STAGE/Contents/MacOS/TapChat"
# The updater (Sparkle), next to the app's code.
ditto "$(dirname "$BIN")/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"
# Math typesetting (SwiftMath): its resources, with only the font TapChat uses.
MATH="$STAGE/Contents/Resources/SwiftMath_SwiftMath.bundle"
ditto "$(dirname "$BIN")/SwiftMath_SwiftMath.bundle" "$MATH"
find "$MATH/Contents/Resources/mathFonts.bundle" -type f ! -name 'latinmodern-math.*' ! -name '*LICENSE*' ! -name 'GUST*' -delete
cp Info.plist "$STAGE/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
# Signed with your Apple Development certificate when there is one (system
# features such as Continuity Camera's Import from iPhone may ignore apps
# signed by nobody); otherwise ad hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')"
codesign --force --sign "${IDENTITY:--}" "$STAGE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${IDENTITY:--}" "$STAGE"

# --release: leave the signed app in build/Release for Scripts/distribute.py; don't install.
if [ "${1:-}" = "--release" ]; then
  rm -rf build/Release && mkdir -p build/Release && mv "$STAGE" build/Release/TapChat.app
  echo "Built build/Release/TapChat.app"
  exit 0
fi

for id in is.dsr.tapchat local.tapchat local.quickchat; do osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true; done
pkill -x TapChat 2>/dev/null || true
pkill -x QuickChat 2>/dev/null || true
rm -rf "$APP" "$OLD" "$OLDER"
mv "$STAGE" "$APP"
# Spotlight and Launchpad pick it up from here.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed $APP"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
