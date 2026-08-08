#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-run}"
APP_NAME="AgentActivity"
BUNDLE_ID="com.adikris.AgentActivity"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    printf 'usage: %s [run|--debug|--logs|--telemetry|--verify]\n' "$0" >&2
    exit 2
    ;;
esac

CONFIGURATION=debug \
VERSION="${VERSION:-0.1.0-dev}" \
BUILD_NUMBER="${BUILD_NUMBER:-0}" \
OUTPUT_DIR="$ROOT_DIR/dist" \
SIGNING_IDENTITY=- \
UNIVERSAL=0 \
  "$SCRIPT_DIR/build_app.sh"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verified_pid=""
    for _ in {1..10}; do
      verified_pid="$(pgrep -x "$APP_NAME" | head -n 1 || true)"
      [[ -n "$verified_pid" ]] && break
      sleep 1
    done
    [[ -n "$verified_pid" ]] || {
      printf 'error: %s did not remain running after launch\n' "$APP_NAME" >&2
      exit 1
    }
    process_name="$(ps -p "$verified_pid" -o comm= | sed 's/^[[:space:]]*//')"
    [[ "$process_name" == "$APP_BINARY" ]] || {
      printf 'error: unexpected process for pid %s: %s\n' "$verified_pid" "$process_name" >&2
      exit 1
    }
    printf 'Verified %s is running as pid %s\n' "$APP_BINARY" "$verified_pid"
    ;;
esac
