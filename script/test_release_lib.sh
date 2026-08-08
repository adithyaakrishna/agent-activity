#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/distribution_verification.sh
source "$SCRIPT_DIR/lib/distribution_verification.sh"

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

assert_rejected() {
  local label="$1"
  shift
  if ("$@" >/dev/null 2>&1); then
    fail "expected rejection: $label"
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

good_env="$fixture_output/good.env"
printf '%s\n' \
  'SIGNING_IDENTITY=Developer\ ID\ Application:\ Fixture\ \(TEAMID\)' \
  'NOTARY_PROFILE=AgentActivity-Notary' > "$good_env"
chmod 600 "$good_env"
SIGNING_IDENTITY=""
NOTARY_PROFILE=""
if load_optional_env "$good_env"; then
  assert_equal "$SIGNING_IDENTITY" 'Developer ID Application: Fixture (TEAMID)'
  assert_equal "$NOTARY_PROFILE" 'AgentActivity-Notary'
else
  fail "expected secure whitelisted environment file to load"
fi

malicious_env="$fixture_output/malicious.env"
malicious_marker="$fixture_output/executed"
printf 'SIGNING_IDENTITY=Developer ID Application: $(touch %s)\n' "$malicious_marker" > "$malicious_env"
chmod 600 "$malicious_env"
if (load_optional_env "$malicious_env" >/dev/null 2>&1); then
  fail "expected executable environment value to be rejected"
fi
[[ ! -e "$malicious_marker" ]] || fail "environment parser executed shell code"

insecure_env="$fixture_output/insecure.env"
printf '%s\n' 'NOTARY_PROFILE=AgentActivity-Notary' > "$insecure_env"
chmod 644 "$insecure_env"
if (load_optional_env "$insecure_env" >/dev/null 2>&1); then
  fail "expected group/world-readable environment file to be rejected"
fi

unknown_env="$fixture_output/unknown.env"
printf '%s\n' 'UNKNOWN_RELEASE_SETTING=value' > "$unknown_env"
chmod 600 "$unknown_env"
if (load_optional_env "$unknown_env" >/dev/null 2>&1); then
  fail "expected unknown environment assignment to be rejected"
fi

fixture_plist="$fixture_output/Info.plist"
cp "$SCRIPT_DIR/../Resources/Info.plist" "$fixture_plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3' "$fixture_plist"
if ! (verify_bundle_metadata "$fixture_plist" 1.2.3 >/dev/null 2>&1); then
  fail "expected valid bundle metadata to pass"
fi

bad_identifier_plist="$fixture_output/BadIdentifier.plist"
cp "$fixture_plist" "$bad_identifier_plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier example.invalid' "$bad_identifier_plist"
assert_rejected "malformed bundle identifier" verify_bundle_metadata "$bad_identifier_plist" 1.2.3

bad_minimum_plist="$fixture_output/BadMinimum.plist"
cp "$fixture_plist" "$bad_minimum_plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 12.0' "$bad_minimum_plist"
assert_rejected "malformed minimum system version" verify_bundle_metadata "$bad_minimum_plist" 1.2.3

bad_ui_element_plist="$fixture_output/BadUIElement.plist"
cp "$fixture_plist" "$bad_ui_element_plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$bad_ui_element_plist"
assert_rejected "malformed menu-bar-only flag" verify_bundle_metadata "$bad_ui_element_plist" 1.2.3

fixture_executable="$fixture_output/AgentActivity"
printf '#!/bin/sh\n' > "$fixture_executable"
chmod 644 "$fixture_executable"
assert_rejected "non-executable bundle binary" verify_executable_file "$fixture_executable" fixture
chmod 755 "$fixture_executable"
if ! (verify_executable_file "$fixture_executable" fixture >/dev/null 2>&1); then
  fail "expected executable bundle binary to pass"
fi

fixture_artifact="$fixture_output/AgentActivity-1.2.3-macos-universal.zip"
printf 'fixture artifact\n' > "$fixture_artifact"
sha256_file "$fixture_artifact"
if ! (verify_checksum_manifest "$fixture_artifact.sha256" "$fixture_artifact" >/dev/null 2>&1); then
  fail "expected exact checksum artifact filename to pass"
fi
fixture_hash="$(shasum -a 256 "$fixture_artifact" | awk '{ print $1 }')"
printf '%s  %s\n' "$fixture_hash" 'AgentActivity-wrong-name.zip' > "$fixture_artifact.sha256"
assert_rejected "checksum naming a different artifact" \
  verify_checksum_manifest "$fixture_artifact.sha256" "$fixture_artifact"

adhoc_report='CodeDirectory v=20400 size=1 flags=0x2(adhoc) hashes=1+2 location=embedded'
runtime_report='CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+2 location=embedded'
if codesign_report_has_flag "$adhoc_report" runtime; then
  fail "ad-hoc signature was falsely reported as hardened runtime"
fi
if ! codesign_report_has_flag "$runtime_report" runtime; then
  fail "hardened-runtime signature flag was not parsed"
fi

fake_hdiutil_dir="$fixture_output/fake-hdiutil"
mkdir -p "$fake_hdiutil_dir"
fake_hdiutil_log="$fixture_output/hdiutil.log"
cat > "$fake_hdiutil_dir/hdiutil" <<'FAKE_HDIUTIL'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_HDIUTIL_LOG"
[[ "$1" == detach ]]
FAKE_HDIUTIL
chmod 755 "$fake_hdiutil_dir/hdiutil"
if (
  export PATH="$fake_hdiutil_dir:$PATH"
  export FAKE_HDIUTIL_LOG="$fake_hdiutil_log"
  attach_dmg_readonly "$fixture_output/partial.dmg" "$fixture_output/partial-mount"
); then
  fail "partially mounted DMG fixture unexpectedly succeeded"
fi
assert_equal "$(tr '\n' ' ' < "$fake_hdiutil_log")" "attach detach "

if ((failures > 0)); then
  printf '%d release library fixture(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'release library fixtures passed\n'
