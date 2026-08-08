#!/bin/zsh

# Privacy-minimized receiver for Cursor and Claude Code command hooks.
# It intentionally never persists prompt text, assistant output, commands, tool
# inputs/results, transcript contents, environment variables, or credentials.

set -u
umask 077

AGENT_ACTIVITY_PROVIDER="${1:-}"
case "$AGENT_ACTIVITY_PROVIDER" in
  cursor|claude) ;;
  *) exit 0 ;;
esac

AGENT_ACTIVITY_JQ=""
for jq_candidate in /opt/homebrew/bin/jq /usr/local/bin/jq; do
  if [ -x "$jq_candidate" ]; then
    AGENT_ACTIVITY_JQ="$jq_candidate"
    break
  fi
done
[ -n "$AGENT_ACTIVITY_JQ" ] || exit 0

AGENT_ACTIVITY_CAPTURED_AT="$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")"
AGENT_ACTIVITY_REMOTE="${CLAUDE_CODE_REMOTE:-}"

AGENT_ACTIVITY_RECORD="$($AGENT_ACTIVITY_JQ -c \
  --arg provider "$AGENT_ACTIVITY_PROVIDER" \
  --arg captured_at "$AGENT_ACTIVITY_CAPTURED_AT" \
  --arg remote "$AGENT_ACTIVITY_REMOTE" '
    if type != "object" then empty else
      # Cursor can optionally import Claude Code hooks. Requiring a native Claude
      # native transcript path prevents those compatibility invocations from
      # being counted a second time under the Claude tab.
      if ($provider == "claude") and (
        ((.transcript_path | type) != "string") or
        ((.transcript_path | contains("/.claude/projects/")) | not)
      ) then empty else
      (if (.workspace_roots | type) == "array"
       then [.workspace_roots[] | select(type == "string")]
       else [] end) as $workspace_roots |
      (if (.cwd | type) == "string" then .cwd
       elif ($workspace_roots | length) > 0 then $workspace_roots[0]
       else null end) as $repository_root |
      (if (.hook_event_name | type) == "string" then .hook_event_name
       elif (.event_name | type) == "string" then .event_name
       else "unknown" end) as $event |
      (if (.tool_name | type) == "string" then .tool_name else null end) as $tool_name |
      (if (.file_path | type) == "string" then .file_path
       elif (.tool_input.file_path | type) == "string" then .tool_input.file_path
       elif (.tool_input.path | type) == "string" then .tool_input.path
       else null end) as $edited_path |
      {
        schema_version: 1,
        provider: $provider,
        captured_at: $captured_at,
        event: $event,
        session_id: (if (.session_id | type) == "string" then .session_id
                     elif (.conversation_id | type) == "string" then .conversation_id
                     else null end),
        generation_id: (if (.generation_id | type) == "string" then .generation_id else null end),
        repository_root: $repository_root,
        workspace_roots: $workspace_roots,
        tool_name: $tool_name,
        agent_id: (if (.agent_id | type) == "string" then .agent_id
                   elif (.subagent_id | type) == "string" then .subagent_id
                   else null end),
        agent_type: (if (.agent_type | type) == "string" then .agent_type
                     elif (.subagent_type | type) == "string" then .subagent_type
                     else null end),
        duration_ms: (if (.duration_ms | type) == "number" then .duration_ms
                      elif (.durationMs | type) == "number" then .durationMs
                      elif (.duration | type) == "number" then .duration
                      else null end),
        status: (if (.status | type) == "string" then .status
                 elif (.reason | type) == "string" then .reason
                 else null end),
        is_background: ((.is_background_agent == true) or ($remote == "true")),
        edits_count: (if (.edits | type) == "array" then (.edits | length) else null end),
        modified_files_count: (if (.modified_files | type) == "array"
                               then (.modified_files | length) else null end),
        edited_file: (
          if (($event == "afterFileEdit") or ($tool_name == "Edit") or ($tool_name == "Write"))
             and ($edited_path != null) and ($repository_root != null)
             and ($edited_path | startswith($repository_root + "/"))
          then ($edited_path | ltrimstr($repository_root + "/"))
          else null end
        )
      } |
      with_entries(select(.value != null))
      end
    end
  ' 2>/dev/null)" || exit 0

[ -n "$AGENT_ACTIVITY_RECORD" ] || exit 0

AGENT_ACTIVITY_EVENT="$(print -r -- "$AGENT_ACTIVITY_RECORD" | $AGENT_ACTIVITY_JQ -r '.event // "unknown"')"
AGENT_ACTIVITY_ROOT_CANDIDATE="$(print -r -- "$AGENT_ACTIVITY_RECORD" | $AGENT_ACTIVITY_JQ -r '.repository_root // empty')"
AGENT_ACTIVITY_REPOSITORY_ROOT=""

if [ -n "$AGENT_ACTIVITY_ROOT_CANDIDATE" ] && [ -d "$AGENT_ACTIVITY_ROOT_CANDIDATE" ]; then
  AGENT_ACTIVITY_REPOSITORY_ROOT="$(/usr/bin/git -C "$AGENT_ACTIVITY_ROOT_CANDIDATE" rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [ -n "$AGENT_ACTIVITY_REPOSITORY_ROOT" ]; then
  AGENT_ACTIVITY_RECORD="$(print -r -- "$AGENT_ACTIVITY_RECORD" | $AGENT_ACTIVITY_JQ -c \
    --arg repository_root "$AGENT_ACTIVITY_REPOSITORY_ROOT" \
    '.repository_root = $repository_root')"

  case "$AGENT_ACTIVITY_EVENT" in
    stop|sessionEnd|SessionEnd|afterFileEdit)
      AGENT_ACTIVITY_HEAD_SHA="$(/usr/bin/git -C "$AGENT_ACTIVITY_REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null || true)"
      AGENT_ACTIVITY_HEAD_COMMITTED_AT="$(/usr/bin/git -C "$AGENT_ACTIVITY_REPOSITORY_ROOT" show -s --format=%cI HEAD 2>/dev/null || true)"
      AGENT_ACTIVITY_LINE_STATS="$(/usr/bin/git -C "$AGENT_ACTIVITY_REPOSITORY_ROOT" show --numstat --format= HEAD 2>/dev/null | /usr/bin/awk 'BEGIN {a=0; d=0} $1 ~ /^[0-9]+$/ {a+=$1} $2 ~ /^[0-9]+$/ {d+=$2} END {printf "%d|%d", a, d}')"
      AGENT_ACTIVITY_ADDITIONS="${AGENT_ACTIVITY_LINE_STATS%%|*}"
      AGENT_ACTIVITY_DELETIONS="${AGENT_ACTIVITY_LINE_STATS##*|}"
      if print -r -- "$AGENT_ACTIVITY_HEAD_SHA" | /usr/bin/grep -Eq '^[0-9a-fA-F]{40}$'; then
        AGENT_ACTIVITY_RECORD="$(print -r -- "$AGENT_ACTIVITY_RECORD" | $AGENT_ACTIVITY_JQ -c \
          --arg head_sha "$AGENT_ACTIVITY_HEAD_SHA" \
          --arg head_committed_at "$AGENT_ACTIVITY_HEAD_COMMITTED_AT" \
          --argjson additions "${AGENT_ACTIVITY_ADDITIONS:-0}" \
          --argjson deletions "${AGENT_ACTIVITY_DELETIONS:-0}" \
          '. + {
            head_sha: $head_sha,
            head_committed_at: $head_committed_at,
            head_additions: $additions,
            head_deletions: $deletions
          }')"
      fi
      ;;
  esac
fi

AGENT_ACTIVITY_INBOX_DIR="${AGENT_ACTIVITY_INBOX_DIR_OVERRIDE:-$HOME/Library/Application Support/AgentActivity/hooks}"
AGENT_ACTIVITY_INBOX="$AGENT_ACTIVITY_INBOX_DIR/$AGENT_ACTIVITY_PROVIDER.jsonl"
/bin/mkdir -p "$AGENT_ACTIVITY_INBOX_DIR" || exit 0

if [ -f "$AGENT_ACTIVITY_INBOX" ]; then
  AGENT_ACTIVITY_INBOX_SIZE="$(/usr/bin/stat -f '%z' "$AGENT_ACTIVITY_INBOX" 2>/dev/null || print 0)"
  if [ "${AGENT_ACTIVITY_INBOX_SIZE:-0}" -gt 26214400 ]; then
    /bin/mv -f "$AGENT_ACTIVITY_INBOX" "$AGENT_ACTIVITY_INBOX.1" 2>/dev/null || true
  fi
fi

print -r -- "$AGENT_ACTIVITY_RECORD" >> "$AGENT_ACTIVITY_INBOX" 2>/dev/null || true
exit 0
