#!/bin/bash
# Builds TapChat at a git revision, installs it, and runs Scripts/bench.sh on
# it several times. Every revision is measured by the same code: the
# benchmark script and the in-app benchmark code (Bench.swift,
# DebugHooks.swift) are this checkout's, copied over the revision's. The
# revision must be 83c1b02 or later (it has ChatModel.simulateAnswer).
#
#   Scripts/compare.sh <rev> <label> [runs]     e.g. Scripts/compare.sh 83c1b02 before 3
#
# Writes bench/<label>-<n>.json. Reinstall the current app afterwards with
# ./build.sh. Don't use TapChat while it runs: clicks change the figures.
set -euo pipefail
cd "$(dirname "$0")/.."
REV="${1:?usage: Scripts/compare.sh <rev> <label> [runs]}"
LABEL="${2:?usage: Scripts/compare.sh <rev> <label> [runs]}"
RUNS="${3:-3}"
ROOT="$(pwd)"
SHA="$(git rev-parse --short "$REV")"
WORK="$HOME/Library/Caches/TapChat-compare/$SHA"

if [ ! -d "$WORK" ]; then
  mkdir -p "$(dirname "$WORK")"
  git worktree add --detach "$WORK" "$SHA" >/dev/null
fi
git -C "$WORK" checkout -q -- .
cp Sources/TapChat/Bench.swift Sources/TapChat/DebugHooks.swift "$WORK/Sources/TapChat/"
echo "building $SHA with this checkout's benchmark code…"
# The revision's own build.sh, but always building outside iCloud.
(cd "$WORK" && swift build -c release --scratch-path "$HOME/Library/Caches/TapChat-build-$SHA" 2>&1 | tail -1)
BIN="$(cd "$WORK" && swift build -c release --scratch-path "$HOME/Library/Caches/TapChat-build-$SHA" --show-bin-path)/TapChat"
APP=/Applications/TapChat.app
osascript -e 'tell application id "is.dsr.tapchat" to quit' >/dev/null 2>&1 || true
pkill -x TapChat 2>/dev/null || true
STAGE="$(mktemp -d)/TapChat.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/TapChat"
cp "$WORK/Info.plist" "$STAGE/Contents/Info.plist"
[ -f "$WORK/AppIcon.icns" ] && cp "$WORK/AppIcon.icns" "$STAGE/Contents/Resources/"
codesign --force --sign - "$STAGE" 2>/dev/null
rm -rf "$APP"
mv "$STAGE" "$APP"

for n in $(seq 1 "$RUNS"); do
  echo "run $n of $RUNS…"
  "$ROOT/Scripts/bench.sh" "$LABEL-$n" >/dev/null
  sleep 3
done
echo "→ bench/$LABEL-1…$RUNS.json"
