#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

assert_valid() {
  local version="$1"
  if ! validate_version "$version"; then
    fail "expected valid version: $version"
  fi
}

assert_invalid() {
  local version="$1"
  if validate_version "$version" >/dev/null 2>&1; then
    fail "expected invalid version: $version"
  fi
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    fail "expected '$expected', got '$actual'"
  fi
}

assert_artifact_stays_within() {
  local output_dir="$1"
  local version="$2"
  local candidate

  if candidate="$(artifact_basename "$version" 2>/dev/null)"; then
    case "$output_dir/$candidate.zip" in
      "$output_dir"/*) ;;
      *) fail "artifact escaped output directory for version: $version" ;;
    esac
  fi
}

assert_artifact_rejected() {
  local output_dir="$1"
  local version="$2"
  if (artifact_basename "$version" >/dev/null 2>&1); then
    fail "artifact basename accepted unsafe version: $version"
  fi
  [[ ! -e "$output_dir/escaped" ]] || fail "unsafe artifact name escaped output directory"
}

assert_valid 0.1.0
assert_valid 1.2.3-beta.1
assert_valid 2.0.0-rc.1

assert_invalid v1.0
assert_invalid 1.0
assert_invalid ' 1.0.0'
assert_invalid '1.0.0 '
assert_invalid '1.0.0; touch /tmp/nope'
assert_invalid '1.0.0/../../escape'
assert_invalid '1.0.0$(touch /tmp/nope)'

assert_equal "$(artifact_basename 1.2.3)" "AgentActivity-1.2.3-macos-universal"

fixture_output="$(mktemp -d "${TMPDIR:-/tmp}/agentactivity-release-test.XXXXXX")"
trap 'rm -rf "$fixture_output"' EXIT
assert_artifact_stays_within "$fixture_output" 0.1.0
assert_artifact_stays_within "$fixture_output" 1.2.3-beta.1
assert_artifact_rejected "$fixture_output" '../escaped'
assert_artifact_rejected "$fixture_output" '1.0.0/../../escaped'

if ((failures > 0)); then
  printf '%d release library fixture(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'release library fixtures passed\n'
