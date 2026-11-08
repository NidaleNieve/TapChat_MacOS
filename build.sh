#!/bin/bash
# Builds QuickChat.app and installs it to /Applications (quits a running copy first).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/QuickChat"
APP="/Applications/QuickChat.app"
OLD="$HOME/Applications/QuickChat.app"
STAGE="$(mktemp -d)/QuickChat.app"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/QuickChat"
cp Info.plist "$STAGE/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGE"

osascript -e 'tell application id "local.quickchat" to quit' >/dev/null 2>&1 || true
pkill -x QuickChat 2>/dev/null || true
rm -rf "$APP" "$OLD"
mv "$STAGE" "$APP"
# Spotlight and Launchpad pick it up from here.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed $APP"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
