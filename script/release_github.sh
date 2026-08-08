#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"

VERSION="${1:-}"
DRY_RUN="${2:-0}"
validate_version "$VERSION" || die "invalid release version: $VERSION"
[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || die "invalid dry-run flag"

load_optional_env "$ROOT_DIR/.env"

if [[ "$DRY_RUN" == 0 ]]; then
  require_command gh
  gh auth status
  [[ "$(git -C "$ROOT_DIR" branch --show-current)" == main ]] || die "release must run from main"
  require_clean_worktree "$ROOT_DIR"
  [[ -z "$(git -C "$ROOT_DIR" tag -l "v$VERSION")" ]] || die "tag v$VERSION already exists"
  SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(find_developer_id_identity)}"
  [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]] || \
    die "real release requires Developer ID signing"
  NOTARY_PROFILE="${NOTARY_PROFILE:-AgentActivity-Notary}"
  NOTARIZE=1
  REQUIRE_NOTARIZATION=1
else
  SIGNING_IDENTITY=-
  NOTARY_PROFILE=AgentActivity-Notary
  NOTARIZE=0
  REQUIRE_NOTARIZATION=0
  printf 'Dry run: signing ad hoc; notarization, tagging, pushing, and publishing are disabled.\n'
fi

bash -n "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib/*.sh
bash "$SCRIPT_DIR/test_release_lib.sh"
swift test --package-path "$ROOT_DIR" --parallel

BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD)"
VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
OUTPUT_DIR="$ROOT_DIR/dist" \
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
NOTARY_PROFILE="$NOTARY_PROFILE" \
NOTARIZE="$NOTARIZE" \
  "$SCRIPT_DIR/build_distribution.sh"
VERSION="$VERSION" \
OUTPUT_DIR="$ROOT_DIR/dist" \
REQUIRE_NOTARIZATION="$REQUIRE_NOTARIZATION" \
  "$SCRIPT_DIR/verify_distribution.sh"

if [[ "$DRY_RUN" == 1 ]]; then
  printf 'Dry run complete; no tag, push, or GitHub release was created.\n'
  exit 0
fi

BASENAME="$(artifact_basename "$VERSION")"
git -C "$ROOT_DIR" tag -a "v$VERSION" -m "AgentActivity $VERSION"
git -C "$ROOT_DIR" push origin "v$VERSION"
gh release create "v$VERSION" \
  "$ROOT_DIR/dist/$BASENAME.dmg" \
  "$ROOT_DIR/dist/$BASENAME.zip" \
  "$ROOT_DIR/dist/$BASENAME.dmg.sha256" \
  "$ROOT_DIR/dist/$BASENAME.zip.sha256" \
  --repo "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" \
  --generate-notes \
  --verify-tag
