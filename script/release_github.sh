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

if [[ "$DRY_RUN" == 0 ]]; then
  require_command gh
  gh auth status
  [[ "$(git -C "$ROOT_DIR" branch --show-current)" == main ]] || die "release must run from main"
  require_clean_worktree "$ROOT_DIR"
  EXPECTED_RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  load_optional_env "$ROOT_DIR/.env"
  SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(find_developer_id_identity)}"
  [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]] || \
    die "real release requires Developer ID signing"
  NOTARY_PROFILE="${NOTARY_PROFILE:-AgentActivity-Notary}"
  NOTARIZE=1
  REQUIRE_NOTARIZATION=1
  REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  [[ -n "$REPOSITORY" ]] || die "could not resolve GitHub repository"
  REPOSITORY_VISIBILITY="$(gh repo view "$REPOSITORY" --json visibility --jq .visibility)"
  [[ "$REPOSITORY_VISIBILITY" == PRIVATE ]] || \
    die "refusing to publish AgentActivity to a non-private repository"

  TAG="v$VERSION"
  LOCAL_TAG_COMMIT="$(git -C "$ROOT_DIR" rev-list -n 1 "$TAG" 2>/dev/null || true)"
  REMOTE_TAG_REFS="$(git -C "$ROOT_DIR" ls-remote --tags origin \
    "refs/tags/$TAG" "refs/tags/$TAG^{}")" || die "could not inspect remote tag $TAG"
  REMOTE_TAG_COMMIT=""
  REMOTE_TAG_DIRECT=""
  while IFS=$'\t' read -r object_id reference; do
    [[ -n "$object_id" ]] || continue
    if [[ "$reference" == "refs/tags/$TAG^{}" ]]; then
      REMOTE_TAG_COMMIT="$object_id"
    elif [[ "$reference" == "refs/tags/$TAG" ]]; then
      REMOTE_TAG_DIRECT="$object_id"
    fi
  done <<< "$REMOTE_TAG_REFS"
  REMOTE_TAG_COMMIT="${REMOTE_TAG_COMMIT:-$REMOTE_TAG_DIRECT}"

  if [[ -n "$LOCAL_TAG_COMMIT" && "$LOCAL_TAG_COMMIT" != "$EXPECTED_RELEASE_COMMIT" ]]; then
    die "local tag $TAG does not resolve to expected release commit $EXPECTED_RELEASE_COMMIT"
  fi
  if [[ -n "$REMOTE_TAG_COMMIT" && "$REMOTE_TAG_COMMIT" != "$EXPECTED_RELEASE_COMMIT" ]]; then
    die "remote tag $TAG does not resolve to expected release commit $EXPECTED_RELEASE_COMMIT"
  fi
else
  SIGNING_IDENTITY=-
  NOTARY_PROFILE=AgentActivity-Notary
  NOTARIZE=0
  REQUIRE_NOTARIZATION=0
  printf 'Dry run: signing ad hoc; notarization, tagging, pushing, and publishing are disabled.\n'
fi

bash -n "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib/*.sh
bash "$SCRIPT_DIR/test_release_lib.sh"
(cd "$ROOT_DIR" && swift format lint --recursive --strict Sources Tests Package.swift)
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
CURRENT_RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
[[ "$CURRENT_RELEASE_COMMIT" == "$EXPECTED_RELEASE_COMMIT" ]] || \
  die "HEAD changed during release verification; expected $EXPECTED_RELEASE_COMMIT, found $CURRENT_RELEASE_COMMIT"
if [[ -z "$LOCAL_TAG_COMMIT" && -z "$REMOTE_TAG_COMMIT" ]]; then
  git -C "$ROOT_DIR" tag -a "$TAG" -m "AgentActivity $VERSION"
  LOCAL_TAG_COMMIT="$EXPECTED_RELEASE_COMMIT"
fi
if [[ -z "$REMOTE_TAG_COMMIT" ]]; then
  git -C "$ROOT_DIR" push origin "$TAG"
fi

ARTIFACTS=(
  "$ROOT_DIR/dist/$BASENAME.dmg"
  "$ROOT_DIR/dist/$BASENAME.zip"
  "$ROOT_DIR/dist/$BASENAME.dmg.sha256"
  "$ROOT_DIR/dist/$BASENAME.zip.sha256"
)
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  gh release edit "$TAG" --repo "$REPOSITORY" --title "AgentActivity $VERSION"
else
  gh release create "$TAG" \
    --repo "$REPOSITORY" \
    --title "AgentActivity $VERSION" \
    --generate-notes \
    --verify-tag
fi
gh release upload "$TAG" "${ARTIFACTS[@]}" \
  --repo "$REPOSITORY" \
  --clobber
