#!/usr/bin/env bash

EXPECTED_BUNDLE_IDENTIFIER="com.adikris.AgentActivity"
EXPECTED_MINIMUM_SYSTEM_VERSION="13.0"

verify_bundle_metadata() {
  local plist="$1"
  local expected_version="$2"

  [[ -f "$plist" ]] || die "bundle Info.plist is missing"
  plutil -lint "$plist" >/dev/null
  verify_plist_value "$plist" CFBundleIdentifier "$EXPECTED_BUNDLE_IDENTIFIER"
  verify_plist_value "$plist" CFBundleShortVersionString "$expected_version"
  verify_plist_value "$plist" CFBundleIconFile AgentActivity
  verify_plist_value "$plist" LSMinimumSystemVersion "$EXPECTED_MINIMUM_SYSTEM_VERSION"
  verify_plist_value "$plist" LSUIElement true
}

verify_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || \
    die "bundle metadata is missing $key"
  [[ "$actual" == "$expected" ]] || \
    die "bundle metadata $key must be $expected (found $actual)"
}

verify_executable_file() {
  local path="$1"
  local label="$2"

  [[ -f "$path" ]] || die "$label is missing"
  [[ -x "$path" ]] || die "$label is not executable"
}

verify_checksum_manifest() {
  local checksum_path="$1"
  local artifact_path="$2"
  local expected_name line_count line hash remainder

  [[ -f "$checksum_path" ]] || die "checksum file is missing: $checksum_path"
  [[ -f "$artifact_path" ]] || die "artifact is missing: $artifact_path"
  expected_name="$(basename "$artifact_path")"
  line_count="$(awk 'END { print NR + 0 }' "$checksum_path")"
  [[ "$line_count" == 1 ]] || die "checksum must contain exactly one record for $expected_name"
  IFS= read -r line < "$checksum_path" || die "checksum record is unreadable: $checksum_path"
  hash="${line%%[[:space:]]*}"
  remainder="${line#"$hash"}"
  [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || die "checksum has an invalid SHA-256 value"
  [[ "$remainder" == "  $expected_name" || "$remainder" == " *$expected_name" ]] || \
    die "checksum must name the exact artifact $expected_name"
  (cd "$(dirname "$artifact_path")" && shasum -a 256 -c "$(basename "$checksum_path")")
}

codesign_report_has_flag() {
  local report="$1"
  local expected_flag="$2"
  local names

  names="$(printf '%s\n' "$report" | sed -n 's/.*flags=0x[[:xdigit:]]*(\([^)]*\)).*/\1/p' | head -n 1)"
  [[ -n "$names" ]] || return 1
  case ",$names," in
    *",$expected_flag,"*) return 0 ;;
    *) return 1 ;;
  esac
}

verify_signature_flags() {
  local target="$1"
  local require_hardened_runtime="$2"
  local report

  report="$(codesign -d --verbose=4 "$target" 2>&1)" || \
    die "could not inspect code-signing flags for $target"
  if [[ "$require_hardened_runtime" == 1 ]] && ! codesign_report_has_flag "$report" runtime; then
    die "credentialed distribution is missing hardened-runtime signing for $target"
  fi
}

attach_dmg_readonly() {
  local image="$1"
  local mount_point="$2"

  if hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$image" >/dev/null; then
    return 0
  fi

  # A failed attach can still leave its requested mount point active.
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  return 1
}
