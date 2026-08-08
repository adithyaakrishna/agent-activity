#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"

VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AgentActivity-Notary}"

validate_version "$VERSION" || die "VERSION must be a semantic version"
[[ "$NOTARIZE" == 0 || "$NOTARIZE" == 1 ]] || die "NOTARIZE must be 0 or 1"
if [[ "$NOTARIZE" == 1 && "$SIGNING_IDENTITY" == "-" ]]; then
  die "notarized distribution requires a Developer ID Application identity"
fi

require_command ditto
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
BASENAME="$(artifact_basename "$VERSION")"
ZIP_PATH="$OUTPUT_DIR/$BASENAME.zip"
DMG_PATH="$OUTPUT_DIR/$BASENAME.dmg"
ASSEMBLY_DIR="$(mktemp -d "$OUTPUT_DIR/.agentactivity-assembly.XXXXXX")"
trap 'rm -rf "$ASSEMBLY_DIR"' EXIT

CONFIGURATION=release \
VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
OUTPUT_DIR="$ASSEMBLY_DIR" \
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
UNIVERSAL=1 \
  "$SCRIPT_DIR/build_app.sh"

APP_BUNDLE="$ASSEMBLY_DIR/AgentActivity.app"
rm -f "$ZIP_PATH" "$DMG_PATH" "$ZIP_PATH.sha256" "$DMG_PATH.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ "$NOTARIZE" == 1 ]]; then
  submit_notarization "$ZIP_PATH" "$NOTARY_PROFILE"
  staple_artifact "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
fi

"$SCRIPT_DIR/create_dmg.sh" "$APP_BUNDLE" "$DMG_PATH"
if [[ "$NOTARIZE" == 1 ]]; then
  submit_notarization "$DMG_PATH" "$NOTARY_PROFILE"
  staple_artifact "$DMG_PATH"
fi

sha256_file "$ZIP_PATH"
sha256_file "$DMG_PATH"
printf 'Distribution artifacts:\n%s\n%s\n' "$ZIP_PATH" "$DMG_PATH"
