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

applications_link="$fixture_output/Applications"
ln -s /Applications "$applications_link"
if ! (verify_applications_symlink "$applications_link" >/dev/null 2>&1); then
  fail "expected exact /Applications symlink to pass"
fi
wrong_applications_link="$fixture_output/WrongApplications"
ln -s /tmp "$wrong_applications_link"
assert_rejected "Applications symlink with wrong target" \
  verify_applications_symlink "$wrong_applications_link"

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
fake_hdiutil_state="$fixture_output/hdiutil.state"
cat > "$fake_hdiutil_dir/hdiutil" <<'FAKE_HDIUTIL'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_HDIUTIL_LOG"
case "$1" in
  attach)
    if ! grep -qx new "$FAKE_HDIUTIL_STATE" 2>/dev/null; then
      printf 'new\n' >> "$FAKE_HDIUTIL_STATE"
    fi
    exit 23
    ;;
  info)
    cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>images</key><array>
PLIST
    if grep -qx existing "$FAKE_HDIUTIL_STATE" 2>/dev/null; then
      cat <<PLIST
<dict>
<key>image-path</key><string>$FAKE_HDIUTIL_IMAGE</string>
<key>system-entities</key><array><dict>
<key>dev-entry</key><string>/dev/disk88</string>
<key>mount-point</key><string>$FAKE_HDIUTIL_EXISTING_MOUNT</string>
</dict></array></dict>
PLIST
    fi
    if grep -qx new "$FAKE_HDIUTIL_STATE" 2>/dev/null; then
      cat <<PLIST
<dict>
<key>image-path</key><string>$FAKE_HDIUTIL_IMAGE</string>
<key>system-entities</key><array><dict>
<key>dev-entry</key><string>/dev/disk99</string>
</dict></array></dict>
PLIST
    fi
    printf '%s\n' '</array></dict></plist>'
    ;;
  detach)
    target="${2:-}"
    if [[ "$target" == -force ]]; then
      target="${3:-}"
    fi
    case "$target" in
      /dev/disk88)
        grep -vx existing "$FAKE_HDIUTIL_STATE" > "$FAKE_HDIUTIL_STATE.next" || true
        mv "$FAKE_HDIUTIL_STATE.next" "$FAKE_HDIUTIL_STATE"
        ;;
      /dev/disk99)
        if [[ "${FAKE_HDIUTIL_DETACH_FAILURE:-0}" == 1 ]]; then
          exit 24
        fi
        grep -vx new "$FAKE_HDIUTIL_STATE" > "$FAKE_HDIUTIL_STATE.next" || true
        mv "$FAKE_HDIUTIL_STATE.next" "$FAKE_HDIUTIL_STATE"
        ;;
      *) exit 25 ;;
    esac
    ;;
  *) exit 26 ;;
esac
FAKE_HDIUTIL
chmod 755 "$fake_hdiutil_dir/hdiutil"
partial_image="$fixture_output/partial.dmg"
partial_mount="$fixture_output/partial-mount"
existing_mount="$fixture_output/pre-existing-mount"
printf 'existing\n' > "$fake_hdiutil_state"
if (
  export PATH="$fake_hdiutil_dir:$PATH"
  export FAKE_HDIUTIL_LOG="$fake_hdiutil_log"
  export FAKE_HDIUTIL_STATE="$fake_hdiutil_state"
  export FAKE_HDIUTIL_IMAGE="$partial_image"
  export FAKE_HDIUTIL_MOUNT="$partial_mount"
  export FAKE_HDIUTIL_EXISTING_MOUNT="$existing_mount"
  attach_dmg_readonly "$partial_image" "$partial_mount"
); then
  fail "partially mounted DMG fixture unexpectedly succeeded"
fi
grep -qx existing "$fake_hdiutil_state" || \
  fail "failed attach detached the pre-existing same-image mount"
if grep -qx new "$fake_hdiutil_state"; then
  fail "failed attach left the newly introduced device attached"
fi
if grep -q '^detach .*disk88' "$fake_hdiutil_log"; then
  fail "failed attach attempted to detach the pre-existing device"
fi

: > "$fake_hdiutil_log"
printf 'existing\n' > "$fake_hdiutil_state"
set +e
detach_failure_output="$(
  {
    export PATH="$fake_hdiutil_dir:$PATH"
    export FAKE_HDIUTIL_LOG="$fake_hdiutil_log"
    export FAKE_HDIUTIL_STATE="$fake_hdiutil_state"
    export FAKE_HDIUTIL_IMAGE="$partial_image"
    export FAKE_HDIUTIL_MOUNT="$partial_mount"
    export FAKE_HDIUTIL_EXISTING_MOUNT="$existing_mount"
    export FAKE_HDIUTIL_DETACH_FAILURE=1
    attach_dmg_readonly "$partial_image" "$partial_mount"
  } 2>&1
)"
detach_failure_status=$?
set -e
[[ "$detach_failure_status" == 2 ]] || \
  fail "detach cleanup failure returned $detach_failure_status instead of 2"
grep -qx existing "$fake_hdiutil_state" || \
  fail "detach cleanup failure detached the pre-existing same-image mount"
grep -qx new "$fake_hdiutil_state" || \
  fail "detach-failure fixture did not retain the new simulated device"
if grep -q '^detach .*disk88' "$fake_hdiutil_log"; then
  fail "detach cleanup failure attempted to detach the pre-existing device"
fi
printf '%s\n' "$detach_failure_output" | grep -q 'could not detach partially attached DMG' || \
  fail "detach cleanup failure was not surfaced"

if ((failures > 0)); then
  printf '%d release library fixture(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'release library fixtures passed\n'
