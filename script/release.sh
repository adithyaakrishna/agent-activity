#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ $# -ge 2 && $# -le 3 ]] || die "usage: $0 github <version> [--dry-run]"
PROVIDER="$1"
VERSION="$2"
DRY_RUN=0
[[ "$PROVIDER" == github ]] || die "unsupported release provider: $PROVIDER"
validate_version "$VERSION" || die "invalid release version: $VERSION"
if [[ $# -eq 3 ]]; then
  [[ "$3" == --dry-run ]] || die "unknown option: $3"
  DRY_RUN=1
fi

exec "$SCRIPT_DIR/release_github.sh" "$VERSION" "$DRY_RUN"
