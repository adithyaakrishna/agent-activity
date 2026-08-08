#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentactivity-github-release-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mkdir -p "$FIXTURE_ROOT/script/lib" "$FIXTURE_ROOT/fake-bin" "$FIXTURE_ROOT/dist"
cp "$SCRIPT_DIR/release_github.sh" "$FIXTURE_ROOT/script/release_github.sh"
cp "$SCRIPT_DIR/lib/common.sh" "$FIXTURE_ROOT/script/lib/common.sh"
cp "$SCRIPT_DIR/lib/signing.sh" "$FIXTURE_ROOT/script/lib/signing.sh"

cat > "$FIXTURE_ROOT/fake-bin/bash" <<'FAKE_BASH'
#!/bin/bash
exit 0
FAKE_BASH

cat > "$FIXTURE_ROOT/fake-bin/swift" <<'FAKE_SWIFT'
#!/bin/bash
printf 'swift %s\n' "$*" >> "$FIXTURE_QUALITY_LOG"
if [[ "${1:-} ${2:-}" == "format lint" && "${SWIFT_FORMAT_FAIL:-0}" == 1 ]]; then
  exit 65
fi
exit 0
FAKE_SWIFT

cat > "$FIXTURE_ROOT/script/build_distribution.sh" <<'FAKE_BUILD'
#!/bin/bash
printf 'build-distribution\n' >> "$FIXTURE_DISTRIBUTION_LOG"
exit 0
FAKE_BUILD

cat > "$FIXTURE_ROOT/script/verify_distribution.sh" <<'FAKE_VERIFY'
#!/bin/bash
exit 0
FAKE_VERIFY

cat > "$FIXTURE_ROOT/fake-bin/git" <<'FAKE_GIT'
#!/bin/bash
set -u
if [[ "${1:-}" == -C ]]; then
  shift 2
fi
case "${1:-} ${2:-} ${3:-}" in
  "branch --show-current ") printf 'main\n' ;;
  "status --porcelain ") ;;
  "rev-list --count HEAD") printf '42\n' ;;
  "rev-list -n 1")
    [[ -n "${LOCAL_TAG_COMMIT:-}" ]] || exit 128
    printf '%s\n' "$LOCAL_TAG_COMMIT"
    ;;
  "rev-parse HEAD ")
    first_head_read=0
    [[ -s "$FIXTURE_HEAD_READ_LOG" ]] || first_head_read=1
    printf 'read\n' >> "$FIXTURE_HEAD_READ_LOG"
    if [[ "$first_head_read" == 1 ]]; then
      printf '%s\n' "$RELEASE_COMMIT"
    else
      printf '%s\n' "${HEAD_AFTER_VERIFY:-$RELEASE_COMMIT}"
    fi
    ;;
  "rev-parse -q --verify")
    [[ -n "${LOCAL_TAG_COMMIT:-}" ]] || exit 1
    printf '%s\n' "$LOCAL_TAG_COMMIT"
    ;;
  "tag -l "*)
    [[ -n "${LOCAL_TAG_COMMIT:-}" ]] && printf 'v0.1.0\n'
    ;;
  "tag -a "*) printf 'git-tag %s\n' "$*" >> "$FIXTURE_MUTATION_LOG" ;;
  "push origin "*) printf 'git-push %s\n' "$*" >> "$FIXTURE_MUTATION_LOG" ;;
  "ls-remote --tags origin")
    if [[ -n "${REMOTE_TAG_COMMIT:-}" ]]; then
      printf 'tag-object\trefs/tags/v0.1.0\n'
      printf '%s\trefs/tags/v0.1.0^{}\n' "$REMOTE_TAG_COMMIT"
    fi
    ;;
  *)
    printf 'unexpected fake git invocation: %s\n' "$*" >&2
    exit 90
    ;;
esac
FAKE_GIT

cat > "$FIXTURE_ROOT/fake-bin/gh" <<'FAKE_GH'
#!/bin/bash
set -u
[[ "${GH_UNAVAILABLE:-0}" == 0 ]] || exit 92
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view")
    case "$*" in
      *'.nameWithOwner'*) printf 'fixture/private-repo\n' ;;
      *'.visibility'*) printf '%s\n' "${REPOSITORY_VISIBILITY:-PRIVATE}" ;;
      *) printf 'fixture/private-repo\n' ;;
    esac
    ;;
  "release view") [[ "${RELEASE_EXISTS:-0}" == 1 ]] ;;
  "release create") printf 'gh-release-create %s\n' "$*" >> "$FIXTURE_MUTATION_LOG" ;;
  "release edit") printf 'gh-release-edit %s\n' "$*" >> "$FIXTURE_MUTATION_LOG" ;;
  "release upload") printf 'gh-release-upload %s\n' "$*" >> "$FIXTURE_MUTATION_LOG" ;;
  *)
    printf 'unexpected fake gh invocation: %s\n' "$*" >&2
    exit 91
    ;;
esac
FAKE_GH

chmod +x "$FIXTURE_ROOT/fake-bin"/* "$FIXTURE_ROOT/script"/*.sh

failures=0
LAST_STATUS=0
LAST_OUTPUT=""
MUTATION_LOG="$FIXTURE_ROOT/mutations.log"
DISTRIBUTION_LOG="$FIXTURE_ROOT/distribution.log"
HEAD_READ_LOG="$FIXTURE_ROOT/head-reads.log"
QUALITY_LOG="$FIXTURE_ROOT/quality.log"
RELEASE_COMMIT=1111111111111111111111111111111111111111

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

write_release_env() {
  printf '%s\n' \
    'SIGNING_IDENTITY=Developer\ ID\ Application:\ Fixture\ \(TEAMID\)' \
    'NOTARY_PROFILE=AgentActivity-Notary' > "$FIXTURE_ROOT/.env"
  chmod 600 "$FIXTURE_ROOT/.env"
}

run_release() {
  local dry_run="$1"
  : > "$MUTATION_LOG"
  : > "$DISTRIBUTION_LOG"
  : > "$HEAD_READ_LOG"
  : > "$QUALITY_LOG"
  set +e
  LAST_OUTPUT="$(env \
    PATH="$FIXTURE_ROOT/fake-bin:/usr/bin:/bin" \
    FIXTURE_MUTATION_LOG="$MUTATION_LOG" \
    FIXTURE_DISTRIBUTION_LOG="$DISTRIBUTION_LOG" \
    FIXTURE_HEAD_READ_LOG="$HEAD_READ_LOG" \
    FIXTURE_QUALITY_LOG="$QUALITY_LOG" \
    RELEASE_COMMIT="$RELEASE_COMMIT" \
    HEAD_AFTER_VERIFY="${HEAD_AFTER_VERIFY:-$RELEASE_COMMIT}" \
    REPOSITORY_VISIBILITY="${REPOSITORY_VISIBILITY:-PRIVATE}" \
    LOCAL_TAG_COMMIT="${LOCAL_TAG_COMMIT:-}" \
    REMOTE_TAG_COMMIT="${REMOTE_TAG_COMMIT:-}" \
    RELEASE_EXISTS="${RELEASE_EXISTS:-0}" \
    GH_UNAVAILABLE="${GH_UNAVAILABLE:-0}" \
    SWIFT_FORMAT_FAIL="${SWIFT_FORMAT_FAIL:-0}" \
    /bin/bash "$FIXTURE_ROOT/script/release_github.sh" 0.1.0 "$dry_run" 2>&1)"
  LAST_STATUS=$?
  set -e
}

assert_no_mutation() {
  [[ ! -s "$MUTATION_LOG" ]] || fail "$1 mutated release state: $(tr '\n' ' ' < "$MUTATION_LOG")"
}

assert_no_distribution() {
  [[ ! -s "$DISTRIBUTION_LOG" ]] || fail "$1 invoked distribution/notarization"
}

# Swift format failure must stop before distribution or publication.
SWIFT_FORMAT_FAIL=1 GH_UNAVAILABLE=1 run_release 1
[[ "$LAST_STATUS" != 0 ]] || fail "dry-run continued after Swift format failure"
assert_no_mutation "Swift format failure"
assert_no_distribution "Swift format failure"
grep -q '^swift format lint --recursive --strict ' "$QUALITY_LOG" || \
  fail "primary local release path did not invoke strict Swift format lint"
SWIFT_FORMAT_FAIL=0

write_release_env
SWIFT_FORMAT_FAIL=1 \
  LOCAL_TAG_COMMIT="$RELEASE_COMMIT" \
  REMOTE_TAG_COMMIT="$RELEASE_COMMIT" \
  RELEASE_EXISTS=1 \
  REPOSITORY_VISIBILITY=PRIVATE \
  GH_UNAVAILABLE=0 \
  run_release 0
[[ "$LAST_STATUS" != 0 ]] || fail "real release continued after Swift format failure"
assert_no_mutation "real-release Swift format failure"
assert_no_distribution "real-release Swift format failure"
SWIFT_FORMAT_FAIL=0

# Dry-run must not parse, validate, or execute .env before choosing isolation.
malicious_marker="$FIXTURE_ROOT/dry-run-env-executed"
printf 'touch %s\n' "$malicious_marker" > "$FIXTURE_ROOT/.env"
chmod 600 "$FIXTURE_ROOT/.env"
LOCAL_TAG_COMMIT="" REMOTE_TAG_COMMIT="" RELEASE_EXISTS=0 REPOSITORY_VISIBILITY=PUBLIC GH_UNAVAILABLE=1 run_release 1
[[ "$LAST_STATUS" == 0 ]] || fail "dry-run failed without a remote repository: $LAST_OUTPUT"
[[ ! -e "$malicious_marker" ]] || fail "dry-run executed malicious .env"
assert_no_mutation "dry-run"
grep -q '^build-distribution$' "$DISTRIBUTION_LOG" || fail "dry-run skipped distribution build"

# Public repository visibility must fail before tag, push, or release mutation.
write_release_env
LOCAL_TAG_COMMIT="" REMOTE_TAG_COMMIT="" RELEASE_EXISTS=0 REPOSITORY_VISIBILITY=PUBLIC GH_UNAVAILABLE=0 run_release 0
[[ "$LAST_STATUS" != 0 ]] || fail "public repository release unexpectedly succeeded"
assert_no_mutation "public repository rejection"
assert_no_distribution "public repository rejection"

# A matching verified tag is resumable and must not be recreated or repushed.
write_release_env
LOCAL_TAG_COMMIT="$RELEASE_COMMIT" REMOTE_TAG_COMMIT="$RELEASE_COMMIT" RELEASE_EXISTS=0 REPOSITORY_VISIBILITY=PRIVATE run_release 0
[[ "$LAST_STATUS" == 0 ]] || fail "matching existing tag did not resume: $LAST_OUTPUT"
grep -q '^gh-release-create ' "$MUTATION_LOG" || fail "resumed release did not create missing GitHub Release"
if grep -Eq '^(git-tag|git-push) ' "$MUTATION_LOG"; then
  fail "matching existing tag was recreated or repushed"
fi
grep -q '^build-distribution$' "$DISTRIBUTION_LOG" || fail "matching existing tag skipped distribution build"

# A mismatched local tag must fail before distribution or notarization.
write_release_env
LOCAL_TAG_COMMIT=2222222222222222222222222222222222222222 REMOTE_TAG_COMMIT="" RELEASE_EXISTS=0 REPOSITORY_VISIBILITY=PRIVATE run_release 0
[[ "$LAST_STATUS" != 0 ]] || fail "mismatched local tag unexpectedly succeeded"
assert_no_mutation "mismatched local tag"
assert_no_distribution "mismatched local tag"

# A mismatched remote tag must fail before distribution, notarization, or mutation.
write_release_env
LOCAL_TAG_COMMIT="" REMOTE_TAG_COMMIT=2222222222222222222222222222222222222222 RELEASE_EXISTS=0 REPOSITORY_VISIBILITY=PRIVATE run_release 0
[[ "$LAST_STATUS" != 0 ]] || fail "mismatched remote tag unexpectedly succeeded"
assert_no_mutation "mismatched remote tag"
assert_no_distribution "mismatched remote tag"

# HEAD must remain the preflight release commit through distribution verification.
write_release_env
LOCAL_TAG_COMMIT="$RELEASE_COMMIT" REMOTE_TAG_COMMIT="$RELEASE_COMMIT" RELEASE_EXISTS=0 REPOSITORY_VISIBILITY=PRIVATE HEAD_AFTER_VERIFY=3333333333333333333333333333333333333333 run_release 0
[[ "$LAST_STATUS" != 0 ]] || fail "release continued after HEAD changed during distribution"
assert_no_mutation "changed HEAD after verification"
grep -q '^build-distribution$' "$DISTRIBUTION_LOG" || fail "HEAD reassertion fixture skipped distribution build"

# An existing release must be updated and receive clobbering uploads.
write_release_env
LOCAL_TAG_COMMIT="$RELEASE_COMMIT" REMOTE_TAG_COMMIT="$RELEASE_COMMIT" RELEASE_EXISTS=1 REPOSITORY_VISIBILITY=PRIVATE run_release 0
[[ "$LAST_STATUS" == 0 ]] || fail "existing GitHub Release did not resume: $LAST_OUTPUT"
grep -q '^gh-release-edit ' "$MUTATION_LOG" || fail "existing GitHub Release was not updated"
grep -q '^gh-release-upload .*--clobber' "$MUTATION_LOG" || fail "existing GitHub Release assets were not uploaded with --clobber"
if grep -q '^gh-release-create ' "$MUTATION_LOG"; then
  fail "existing GitHub Release was recreated"
fi

if ((failures > 0)); then
  printf '%d GitHub release fixture(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'GitHub release flow fixtures passed\n'
