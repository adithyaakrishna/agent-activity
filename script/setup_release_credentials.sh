#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"

[[ "${1:-}" == github && $# -eq 1 ]] || die "usage: $0 github"
require_command gh
require_command xcrun
gh auth status

SIGNING_IDENTITY="$(find_developer_id_identity)" || \
  die "no Developer ID Application identity found"
NOTARY_PROFILE=AgentActivity-Notary
xcrun notarytool store-credentials "$NOTARY_PROFILE"

ENV_FILE="$ROOT_DIR/.env"
if ! git -C "$ROOT_DIR" check-ignore -q "$ENV_FILE"; then
  EXCLUDE_FILE="$(git -C "$ROOT_DIR" rev-parse --git-path info/exclude)"
  printf '\n.env\n' >> "$EXCLUDE_FILE"
fi
umask 077
{
  printf 'SIGNING_IDENTITY=%q\n' "$SIGNING_IDENTITY"
  printf 'NOTARY_PROFILE=%q\n' "$NOTARY_PROFILE"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
printf 'Stored release identity and notary profile names in ignored %s\n' "$ENV_FILE"
