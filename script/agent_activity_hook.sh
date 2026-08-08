#!/bin/zsh

set -u

case "${1:-}" in
  cursor|claude) ;;
  *) exit 0 ;;
esac

AGENT_ACTIVITY_SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
"$AGENT_ACTIVITY_SCRIPT_DIRECTORY/../.build/debug/AgentActivityHook" capture "$1" >/dev/null 2>&1 || true
exit 0
