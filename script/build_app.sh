#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"

CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-0.1.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-0}"

validate_version "$VERSION" || die "invalid VERSION: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must contain only digits"
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || \
  die "CONFIGURATION must be debug or release"
[[ "$UNIVERSAL" == 0 || "$UNIVERSAL" == 1 ]] || die "UNIVERSAL must be 0 or 1"

require_command swift
require_command codesign
require_command /usr/libexec/PlistBuddy

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
[[ "$OUTPUT_DIR" != / ]] || die "refusing to use filesystem root as OUTPUT_DIR"

APP_BUNDLE="$OUTPUT_DIR/AgentActivity.app"
CONTENTS="$APP_BUNDLE/Contents"
MAIN_BINARY="$CONTENTS/MacOS/AgentActivity"
HELPER_BINARY="$CONTENTS/Helpers/AgentActivityHook"
ICON_FILE="$CONTENTS/Resources/AgentActivity.icns"
INFO_PLIST="$CONTENTS/Info.plist"
SCRATCH_ROOT="$ROOT_DIR/.build/release-tooling/$CONFIGURATION"

if [[ "$UNIVERSAL" == 1 ]]; then
  architectures=(arm64 x86_64)
else
  architectures=("$(uname -m)")
fi

main_inputs=()
helper_inputs=()
for architecture in "${architectures[@]}"; do
  scratch="$SCRATCH_ROOT/$architecture"
  swift build \
    --package-path "$ROOT_DIR" \
    --configuration "$CONFIGURATION" \
    --arch "$architecture" \
    --scratch-path "$scratch" \
    --product AgentActivity
  swift build \
    --package-path "$ROOT_DIR" \
    --configuration "$CONFIGURATION" \
    --arch "$architecture" \
    --scratch-path "$scratch" \
    --product AgentActivityHook
  bin_path="$(swift build \
    --package-path "$ROOT_DIR" \
    --configuration "$CONFIGURATION" \
    --arch "$architecture" \
    --scratch-path "$scratch" \
    --show-bin-path)"
  main_inputs+=("$bin_path/AgentActivity")
  helper_inputs+=("$bin_path/AgentActivityHook")
done

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"

if [[ "$UNIVERSAL" == 1 ]]; then
  require_command lipo
  lipo -create "${main_inputs[@]}" -output "$MAIN_BINARY"
  lipo -create "${helper_inputs[@]}" -output "$HELPER_BINARY"
else
  cp "${main_inputs[0]}" "$MAIN_BINARY"
  cp "${helper_inputs[0]}" "$HELPER_BINARY"
fi

chmod 755 "$MAIN_BINARY" "$HELPER_BINARY"
cp "$ROOT_DIR/Assets/AgentActivity.icns" "$ICON_FILE"
cp "$ROOT_DIR/Resources/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

codesign_bundle "$SIGNING_IDENTITY" "$HELPER_BINARY"
codesign_bundle "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

printf 'Built %s\n' "$APP_BUNDLE"
