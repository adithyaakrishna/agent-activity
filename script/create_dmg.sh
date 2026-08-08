#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ $# -eq 2 ]] || die "usage: $0 <AgentActivity.app> <output.dmg>"
APP_BUNDLE="$1"
OUTPUT_DMG="$2"

[[ -d "$APP_BUNDLE" ]] || die "app bundle not found: $APP_BUNDLE"
require_command hdiutil
require_command ditto

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentactivity-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "$STAGING_DIR/AgentActivity.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"
hdiutil create \
  -volname AgentActivity \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$OUTPUT_DMG"
