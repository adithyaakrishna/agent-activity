#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

VERSION="${VERSION:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"

validate_version "$VERSION" || die "VERSION must be a semantic version"
[[ "$REQUIRE_NOTARIZATION" == 0 || "$REQUIRE_NOTARIZATION" == 1 ]] || \
  die "REQUIRE_NOTARIZATION must be 0 or 1"

for command in plutil lipo codesign hdiutil ditto shasum; do
  require_command "$command"
done

OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
BASENAME="$(artifact_basename "$VERSION")"
ZIP_PATH="$OUTPUT_DIR/$BASENAME.zip"
DMG_PATH="$OUTPUT_DIR/$BASENAME.dmg"
[[ -f "$ZIP_PATH" && -f "$DMG_PATH" ]] || die "distribution artifacts are missing"
[[ -f "$ZIP_PATH.sha256" && -f "$DMG_PATH.sha256" ]] || die "checksum files are missing"

(cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$ZIP_PATH.sha256")")
(cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$DMG_PATH.sha256")")

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentactivity-verify.XXXXXX")"
MOUNT_POINT="$VERIFY_ROOT/mount"
EXTRACT_DIR="$VERIFY_ROOT/extracted"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$VERIFY_ROOT"
}
trap cleanup EXIT
mkdir -p "$MOUNT_POINT" "$EXTRACT_DIR"

ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"
APP_BUNDLE="$EXTRACT_DIR/AgentActivity.app"
[[ -d "$APP_BUNDLE" ]] || die "ZIP does not contain AgentActivity.app"

verify_app() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local main="$app/Contents/MacOS/AgentActivity"
  local helper="$app/Contents/Helpers/AgentActivityHook"
  local icon="$app/Contents/Resources/AgentActivity.icns"

  plutil -lint "$plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$VERSION" ]] || \
    die "bundle version does not match $VERSION"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" == AgentActivity ]] || \
    die "bundle icon name is not AgentActivity"
  [[ -f "$main" && -f "$helper" && -f "$icon" ]] || die "bundle contents are incomplete"
  lipo "$main" -verify_arch arm64 x86_64
  lipo "$helper" -verify_arch arm64 x86_64
  codesign --verify --deep --strict "$app"
}

verify_app "$APP_BUNDLE"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
mounted=1
[[ -L "$MOUNT_POINT/Applications" ]] || die "DMG is missing Applications symlink"
verify_app "$MOUNT_POINT/AgentActivity.app"

if [[ "$REQUIRE_NOTARIZATION" == 1 ]]; then
  require_command spctl
  require_command xcrun
  codesign -d --verbose=4 "$APP_BUNDLE"
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  xcrun stapler validate "$DMG_PATH"
fi

hdiutil detach "$MOUNT_POINT" >/dev/null
mounted=0
printf 'Verified distribution for %s\n' "$VERSION"
