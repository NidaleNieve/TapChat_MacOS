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

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/TapChat"
cp Info.plist "$STAGE/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGE"

for id in local.tapchat local.quickchat; do osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true; done
pkill -x TapChat 2>/dev/null || true
pkill -x QuickChat 2>/dev/null || true
rm -rf "$APP" "$OLD" "$OLDER"
mv "$STAGE" "$APP"
# Spotlight and Launchpad pick it up from here.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed $APP"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
