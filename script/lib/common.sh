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
  local file_owner file_mode current_owner line line_number key encoded_value
  local parsed_signing_identity=""
  local parsed_notary_profile=""
  local saw_signing_identity=0
  local saw_notary_profile=0

  [[ -e "$env_file" ]] || return 0
  [[ -f "$env_file" && ! -L "$env_file" ]] || die "release environment must be a regular file"
  require_command stat
  require_command id
  file_owner="$(stat -f '%u' "$env_file")"
  file_mode="$(stat -f '%Lp' "$env_file")"
  current_owner="$(id -u)"
  [[ "$file_owner" == "$current_owner" ]] || die "release environment is not owned by the current user"
  [[ "$file_mode" =~ ^[0-7]{3,4}$ ]] || die "cannot validate release environment permissions"
  (( (8#$file_mode & 8#077) == 0 )) || \
    die "release environment must not be group/world-readable"

  line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    case "$line" in
      SIGNING_IDENTITY=*)
        ((saw_signing_identity == 0)) || die "duplicate SIGNING_IDENTITY in release environment"
        key=SIGNING_IDENTITY
        encoded_value="${line#SIGNING_IDENTITY=}"
        saw_signing_identity=1
        ;;
      NOTARY_PROFILE=*)
        ((saw_notary_profile == 0)) || die "duplicate NOTARY_PROFILE in release environment"
        key=NOTARY_PROFILE
        encoded_value="${line#NOTARY_PROFILE=}"
        saw_notary_profile=1
        ;;
      *) die "malformed or unknown release environment line $line_number" ;;
    esac

    decode_release_env_value "$encoded_value"
    if [[ "$key" == SIGNING_IDENTITY ]]; then
      [[ "$RELEASE_ENV_VALUE" == Developer\ ID\ Application:\ * ]] || \
        die "invalid SIGNING_IDENTITY in release environment"
      case "$RELEASE_ENV_VALUE" in
        *'$'*|*'`'*|*';'*|*'|'*|*'<'*|*'>')
          die "invalid SIGNING_IDENTITY in release environment"
          ;;
      esac
      parsed_signing_identity="$RELEASE_ENV_VALUE"
    else
      [[ "$RELEASE_ENV_VALUE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "invalid NOTARY_PROFILE in release environment"
      parsed_notary_profile="$RELEASE_ENV_VALUE"
    fi
  done < "$env_file"

  ((saw_signing_identity == 1 || saw_notary_profile == 1)) || \
    die "release environment contains no settings"
  if ((saw_signing_identity == 1)); then
    SIGNING_IDENTITY="$parsed_signing_identity"
  fi
  if ((saw_notary_profile == 1)); then
    NOTARY_PROFILE="$parsed_notary_profile"
  fi
}

decode_release_env_value() {
  local encoded="$1"
  local decoded=""
  local character next_character
  local index=0
  local length="${#encoded}"

  while ((index < length)); do
    character="${encoded:index:1}"
    if [[ "$character" == \\ ]]; then
      index=$((index + 1))
      ((index < length)) || die "release environment value has a trailing escape"
      next_character="${encoded:index:1}"
      decoded+="$next_character"
    else
      decoded+="$character"
    fi
    index=$((index + 1))
  done
  RELEASE_ENV_VALUE="$decoded"
}

require_clean_worktree() {
  local repository="${1:-.}"
  require_command git
  [[ -z "$(git -C "$repository" status --porcelain)" ]] || \
    die "release requires a clean worktree"
}
