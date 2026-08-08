#!/usr/bin/env bash

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_version() {
  local version="${1:-}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]
}

artifact_basename() {
  local version="${1:-}"
  validate_version "$version" || die "invalid release version: $version"
  printf 'AgentActivity-%s-macos-universal\n' "$version"
}

sha256_file() {
  local artifact="$1"
  local output="${2:-$artifact.sha256}"
  local artifact_dir artifact_name output_name

  require_command shasum
  [[ -f "$artifact" ]] || die "artifact not found: $artifact"
  artifact_dir="$(cd "$(dirname "$artifact")" && pwd)"
  artifact_name="$(basename "$artifact")"
  output_name="$(basename "$output")"
  [[ "$(cd "$(dirname "$output")" && pwd)" == "$artifact_dir" ]] || \
    die "checksum must be adjacent to artifact: $artifact"
  (cd "$artifact_dir" && shasum -a 256 "$artifact_name" > "$output_name")
}

load_optional_env() {
  local env_file="$1"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  fi
}

require_clean_worktree() {
  local repository="${1:-.}"
  require_command git
  [[ -z "$(git -C "$repository" status --porcelain)" ]] || \
    die "release requires a clean worktree"
}
