#!/usr/bin/env bash

find_developer_id_identity() {
  local identities identity
  require_command security
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  identity="$(printf '%s\n' "$identities" | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\(Developer ID Application:.*\)"$/\1/p' | head -n 1)"
  [[ -n "$identity" ]] || return 1
  printf '%s\n' "$identity"
}

codesign_bundle() {
  local identity="$1"
  local target="$2"

  require_command codesign
  [[ -e "$target" ]] || die "cannot sign missing target: $target"
  if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$target"
  else
    [[ "$identity" == Developer\ ID\ Application:* ]] || \
      die "distribution signing requires a Developer ID Application identity"
    codesign --force --timestamp --options runtime --sign "$identity" "$target"
  fi
}

submit_notarization() {
  local artifact="$1"
  local profile="$2"

  [[ -n "$profile" ]] || die "NOTARY_PROFILE is required for notarization"
  [[ -f "$artifact" ]] || die "cannot notarize missing artifact: $artifact"
  require_command xcrun
  xcrun notarytool submit "$artifact" --keychain-profile "$profile" --wait
}

staple_artifact() {
  local artifact="$1"
  require_command xcrun
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
}
