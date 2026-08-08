# Agent Activity data sources

Research date: 2026-08-08

This note describes the supported ways to populate AgentActivity from Cursor, OpenAI Codex, Anthropic Claude Code, local Git, and GitHub. It deliberately distinguishes provider activity from execution location and from repository activity; collapsing those concepts would double-count work and make commit attribution look more precise than the source data allows.

## Recommended product decision

Use these top-level provider tabs:

1. **Cursor**
2. **Codex**
3. **Claude**
4. **GitHub**
5. **Others**

The existing **Cloud** label is ambiguous. Cursor, Codex, and Claude all have hosted/cloud execution. Anthropic's product is called **Claude Code**, while Cursor's hosted product is explicitly called **Cloud Agents** and OpenAI's hosted product is **Codex cloud**. If the intended third provider was Anthropic, rename the tab to **Claude**. Model execution location separately as `local`, `cloud`, `ide`, `cli`, or `web` so, for example, a Cursor Cloud Agent remains a Cursor event with `executionLocation = cloud`.

The GitHub tab should be a separate view of repository contributions. A commit that Cursor produced and GitHub received is one commit with two relationships, not two commits. Provider tabs answer “which agent did I work with?”; GitHub answers “what repository activity appeared on GitHub?”

## What is actually available

| Source | Personal/local support | Hosted support | Tokens | Exact commit attribution |
| --- | --- | --- | --- | --- |
| Cursor | Stable hooks for new activity; CLI structured output for runs. Existing editor history is local SQLite but its schema is not documented. | Cloud Agents API lists agents/runs, streams run events, returns duration/result/branch state, and exposes per-run usage. | Exact for Cloud Agents. Team Admin API has granular usage events. No documented personal API for historical IDE token usage. | Enterprise AI Code Tracking API can attribute commit lines and conversation IDs. Otherwise derive cautiously. |
| Codex | App Server can list/read stored threads and stream turn/item/token events. `codex exec --json` emits structured usage. OTel can export local metrics. | `codex cloud list --json` lists recent cloud chats and status. Enterprise Analytics API offers aggregated reporting. | `account/usage/read` gives daily ChatGPT token buckets; active thread events and `codex exec --json` give more detail. Public cloud-task listing does not expose per-task tokens. | No documented public per-commit attribution API. Link provider activity to Git with stored Git metadata, branch, changed paths, and time, preserving confidence. |
| Claude Code | Stable hooks, OTel, and status-line JSON. Local transcripts are JSONL, but Anthropic says the record format is internal and can change. | Claude Code on the web can be monitored with `/tasks`; project hooks run in cloud sessions. No public session-list REST API is documented. | OTel provides per-session token/cost metrics. The organization Analytics API gives daily per-user tokens, sessions, lines, commits, and PRs. | Analytics/OTel provide commit counts, not commit SHAs. Correlate with Git unless a workflow records the SHA itself. |
| GitHub | Not applicable | GraphQL contribution calendar plus REST commit details. | Not an inference source. | Exact Git SHA/author/repository data, but not which coding agent created the work. |
| Local Git | Scan only user-selected repositories. | Not applicable | Not an inference source. | Canonical local commit history, authors, dates, and numstat. Agent attribution remains a separate relationship. |

## Cursor

### Cursor local/editor activity

Cursor documents that foreground Agent chat history is stored locally in SQLite, while background/cloud conversations are stored remotely ([Cursor History](https://docs.cursor.com/en/agent/chat/history)). The page does not publish the SQLite schema. Reading that database can be offered as an explicitly labelled compatibility importer, but it should not be the primary integration because an app update can change the schema.

For durable collection going forward, use [Cursor hooks](https://cursor.com/docs/hooks). Hooks receive a stable `conversation_id`, a per-user-message `generation_id`, model/model parameters, Cursor version, workspace roots, user email, and an optional `transcript_path`. Useful events include:

- `sessionStart`: `session_id`, `is_background_agent`, `composer_mode`.
- `beforeSubmitPrompt`: one user activity/turn without needing to retain prompt text.
- `afterFileEdit`: exact file path and edit operations; discard code text after deriving counts.
- `postToolUse` / `postToolUseFailure`: tool identity, duration, and outcome.
- `subagentStart` / `subagentStop`: subagent ID/type, duration, tool-call count, status, and modified files.
- `stop`: completed/aborted/error for an agent loop.
- `sessionEnd`: end reason, duration, foreground/background flag, final status.

Install an opt-in user-level hook that appends privacy-minimized JSON records to an AgentActivity inbox. Do not capture prompt, assistant-thought, tool output, file contents, or transcript contents by default. Hooks are the stable contract; `transcript_path` is a pointer, not permission to ingest the transcript.

For runs launched through Cursor CLI, `agent --print --output-format stream-json` produces NDJSON containing session initialization, user/assistant messages, tool calls, and a final result with duration and `session_id` ([Cursor CLI output format](https://cursor.com/docs/cli/reference/output-format)). It does not document token usage, so this is useful for session/run counts and tool activity, not historical tokens.

### Cursor Cloud Agents API

The [Cloud Agents API v1](https://cursor.com/docs/cloud-agent/api/endpoints) is currently public beta. It supports Basic or Bearer authentication with a user or service-account API key.

Read-only endpoints needed by AgentActivity:

| Endpoint | Use |
| --- | --- |
| `GET /v1/agents?limit=100&cursor=...` | Durable agents: ID, name, status, environment, URL, created/updated time, latest run ID. |
| `GET /v1/agents/{agentId}` | Full agent metadata, repositories, starting refs, and current branch settings. |
| `GET /v1/agents/{agentId}/runs?limit=100&cursor=...` | Runs with ID, status, timestamps, and current Git branch snapshot. |
| `GET /v1/agents/{agentId}/runs/{runId}` | Terminal result text, `durationMs`, and pushed branches/PRs when available. |
| `GET /v1/agents/{agentId}/runs/{runId}/stream` | SSE status, assistant, tool-call, richer interaction, result, and done events. Stream retention is finite; fall back to Get Run after expiry. |
| `GET /v1/agents/{agentId}/usage[?runId=...]` | Exact per-run and total `inputTokens`, `outputTokens`, `cacheWriteTokens`, `cacheReadTokens`, and `totalTokens`. |

Important attribution caveat: `Run.git` is documented as a **per-agent snapshot, not per-run state**. The SSE result is better for observing when a branch first appears, but the branch still belongs to the persistent agent workspace. Do not claim that all commits currently on the branch came from one specific follow-up run.

### Cursor team and enterprise data

Team administrators can create Admin API keys. The [Cursor Admin API](https://cursor.com/docs/account/teams/admin-api) provides:

- `POST /teams/daily-usage-data`: daily active state, total/accepted lines, applies/accepts/rejects, Tab activity, chat/Composer/Agent requests, model, client version, and user email. Date windows are capped; use pagination/windowing as documented.
- `POST /teams/filtered-usage-events`: hourly-aggregated usage records with timestamp, model, `conversationId`, optional `cloudAgentId`, token counts, charge fields, and headless/cloud flags. Cursor recommends polling this endpoint no more than hourly. Use `conversationId` to join usage to hook or AI-code records.

Cursor's [AI Code Tracking API](https://cursor.com/docs/account/teams/ai-code-tracking-api) is Enterprise-only and alpha, but it is the strongest available commit-attribution source:

- `GET /analytics/ai-code/commits`: commit SHA, user, repo, branch, primary-branch flag, `commitSource` (`ide`, `cli`, or `cloud`), total lines, Tab lines, Composer lines, non-AI lines, message, and commit timestamp.
- `GET /analytics/ai-code/changes`: accepted AI changes with source, model, line counts, timestamp, and privacy-dependent file metadata.
- `GET /analytics/ai-code/commits/{sha[,sha...]}`: limited-alpha blame annotations that can link ranges to `conversationId`, model, and conversation summaries.

Use this API when available. For a personal Cursor account, show tokens or exact agent-to-commit attribution as unavailable rather than manufacturing them from undocumented SQLite fields.

## OpenAI Codex

### Local threads and live activity

The supported integration surface is [Codex App Server](https://learn.chatgpt.com/docs/app-server), the JSON-RPC interface used by rich Codex clients. Start `codex app-server` over JSONL stdio or a local WebSocket/Unix socket, send `initialize` and `initialized`, then use:

| Method/event | Use |
| --- | --- |
| `thread/list` | Page stored threads by created/updated/recency time, source kind, cwd, archived state, and other documented filters. |
| `thread/read` with `includeTurns: true` | Read persisted turn/item history without resuming or subscribing. |
| `thread/turns/list` and `thread/items/list` | Experimental paginated stored activity; opt into the experimental capability and version-gate it. |
| `thread/status/changed` | Active/idle/waiting state for loaded threads. |
| `turn/started`, `turn/completed` | Root activity and outcome. |
| `turn/diff/updated` | Aggregated unified diff while a turn runs. Derive changed-file/line counts, then discard diff text. |
| `item/started`, `item/completed` | Commands, file changes, MCP calls, messages, and other work units. |
| `thread/tokenUsage/updated` | Live token updates for the active thread; generate schemas from the installed Codex version because payloads are version-specific. |
| `account/usage/read` | ChatGPT-backed lifetime/peak/streak summary and optional daily `{startDate, tokens}` buckets. This does not work with API-key-only or Bedrock authentication. |

`thread/list` source kinds distinguish `cli`, `vscode`, `exec`, `appServer`, and several subagent kinds. Use root thread IDs for “things worked on” and child thread/subagent IDs for “agents involved.”

For noninteractive work, `codex exec --json` emits JSONL and a final `turn.completed` event with `input_tokens`, `cached_input_tokens`, `output_tokens`, and `reasoning_output_tokens` ([Codex non-interactive mode](https://learn.chatgpt.com/docs/codex/noninteractive)).

Codex persists state under `CODEX_HOME` (normally `~/.codex`) and can retain `history.jsonl`, but App Server is preferable to parsing files directly. Never read or copy `auth.json`; OpenAI explicitly treats it as a credential containing access tokens. History can be disabled or capped with `[history]` settings ([Codex advanced configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#history-persistence)).

### Codex telemetry

Codex OpenTelemetry export is opt-in and disabled by default. It can emit structured API, stream, prompt-metadata, tool-decision, and tool-result events plus metrics including per-turn token usage and tool calls. Prompt text is redacted unless the user separately enables prompt logging ([Codex configuration and telemetry](https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry)). OTel is the best source for new local token/tool activity when the app is allowed to help configure a local collector; App Server remains the better source for conversation history.

### Codex cloud

The current CLI has a documented, scriptable cloud listing ([Codex CLI cloud commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli#cli-codex-cloud)):

```text
codex cloud list --json --limit 20 [--cursor CURSOR] [--env ENV_ID]
```

The JSON contains a `tasks` array and optional pagination cursor. Each task includes `id`, `url`, `title`, `status`, `updated_at`, `environment_id`, `environment_label`, `summary`, `is_review`, and `attempt_total`. This supports cloud heatmap activity, task counts, status, and environment hover details. It does **not** document per-task token usage or commit SHA fields.

For Enterprise workspaces, the [Codex Analytics API](https://learn.chatgpt.com/docs/enterprise/analytics-api) provides aggregated reporting, while the Compliance API is intended for audit records. Their authenticated references own the current routes and schemas. They are workspace/admin surfaces, not a personal-account fallback.

### Codex commit attribution boundary

App Server threads can contain persisted Git metadata and file-change/command items, and cloud tasks expose status/summary. None of the public personal contracts above is an exact “commit SHA created by this thread” history endpoint. Therefore:

1. Ingest the canonical commit from local Git or GitHub.
2. Join to a Codex thread/task using explicit stored branch/repository metadata first.
3. Improve a match with overlapping changed paths and a commit timestamp shortly after the turn.
4. Store the relationship as `derived` with a confidence and reasons; never present it as provider-verified.

## Anthropic Claude Code

### Why this should be a Claude tab, not a Cloud tab

Claude Code is a provider/product. It can execute locally or in an Anthropic-managed cloud VM. Anthropic's [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) uses `/tasks` to monitor hosted sessions, `--remote` to create one, and `--teleport` to pull one back locally. The docs do not publish a REST endpoint for listing a user's web sessions. Treat `claude` as the provider and `local|cloud` as execution location.

Cloud project hooks committed in `.claude/settings.json` run in hosted sessions. `CLAUDE_CODE_REMOTE=true` identifies that environment, and `CLAUDE_CODE_REMOTE_SESSION_ID` can provide a traceable session ID. A project hook can send privacy-minimized activity to a user-controlled collector when the cloud environment's network policy allows it. User-level `~/.claude` hooks do not automatically exist in cloud VMs.

### Stable local collection

Use [Claude Code hooks](https://code.claude.com/docs/en/hooks) for session lifecycle and exact action timing. Common fields include `session_id`, `transcript_path`, cwd, permission mode, and agent type. High-value events are:

- `SessionStart` / `SessionEnd` for session counts and duration.
- `UserPromptSubmit` for turn activity without persisting prompt text.
- `PostToolUse` / `PostToolUseFailure` for tool counts and outcomes.
- `SubagentStart` / `SubagentStop` for agent IDs/types and child transcript pointers.
- `Stop` / `StopFailure` for completion status.

Claude stores local transcripts in plaintext JSONL at `~/.claude/projects/<project>/<session-id>.jsonl` for 30 days by default. Anthropic explicitly says each line's format is internal and can change between releases; use `/export` or hooks/script interfaces instead of building a hard dependency on raw records ([Claude sessions](https://code.claude.com/docs/en/sessions)). Respect `CLAUDE_CONFIG_DIR`, `cleanupPeriodDays`, `CLAUDE_CODE_SKIP_PROMPT_HISTORY`, and `--no-session-persistence`.

### Tokens, cost, lines, and commits

[Claude Code OpenTelemetry](https://code.claude.com/docs/en/monitoring-usage) is the most complete stable feed for new activity. After `CLAUDE_CODE_ENABLE_TELEMETRY=1`, useful metrics include:

- `claude_code.session.count`
- `claude_code.lines_of_code.count`
- `claude_code.commit.count`
- `claude_code.pull_request.count`
- `claude_code.cost.usage`
- `claude_code.token.usage`, with token type `input`, `output`, `cacheRead`, or `cacheCreation`
- `claude_code.active_time.total`

Metrics/events carry `session.id`, model, user identity when available, and optional agent/skill/plugin dimensions. Note that commit and PR metrics count actions created through Claude Code functionality; they do not identify a SHA and do not prove that a later manual commit was wholly agent-authored.

The [status-line interface](https://code.claude.com/docs/en/statusline) is also stable and local. Its stdin JSON contains `session_id`, `transcript_path`, estimated `cost.total_cost_usd`, elapsed/API duration, lines added/removed, model, workspace, and current context-window token fields. Context token fields describe the latest/current context, not cumulative session token usage, so use OTel for calendar token totals. A status-line helper may write snapshots to the same local inbox if the user does not want an OTel collector.

Organizations can use the [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api):

```http
GET https://api.anthropic.com/v1/organizations/usage_report/claude_code?starting_at=YYYY-MM-DD&limit=1000
anthropic-version: 2023-06-01
x-api-key: <ADMIN_API_KEY>
```

It returns one UTC day's per-actor data: session count, lines added/removed, commits, PRs, terminal type, tool accept/reject counts, and per-model input/output/cache tokens plus estimated cost. Data can lag by up to one hour. The Admin API is unavailable to individual accounts and requires an organization Admin API key (or the applicable organization OAuth/Analytics credential); Claude Enterprise uses its separately documented Analytics API key path ([Anthropic Admin API access](https://platform.claude.com/docs/en/manage-claude/overview)).

## GitHub activity tab

### Primary heatmap query

Use GitHub GraphQL `User.contributionsCollection(from:to:)`. The official schema provides the same calendar concepts needed by the UI: weeks, days, `date`, `weekday`, `contributionCount`, `contributionLevel`, color, total contributions, plus total commits, issues, pull requests, reviews, repositories, and restricted counts ([GitHub `ContributionsCollection`](https://docs.github.com/en/graphql/reference/users#contributionscollection), [commit contributions by repository](https://docs.github.com/en/graphql/reference/commits#commitcontributionsbyrepository)).

Suggested query:

```graphql
query Activity($login: String!, $from: DateTime!, $to: DateTime!) {
  user(login: $login) {
    contributionsCollection(from: $from, to: $to) {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date
            weekday
            contributionCount
            contributionLevel
            color
          }
        }
      }
      totalCommitContributions
      totalIssueContributions
      totalPullRequestContributions
      totalPullRequestReviewContributions
      totalRepositoriesWithContributedCommits
      restrictedContributionsCount
      commitContributionsByRepository(maxRepositories: 100) {
        repository { nameWithOwner url isPrivate }
        contributions(first: 100) {
          totalCount
          nodes { occurredAt commitCount }
        }
      }
    }
  }
}
```

Use an OAuth/GitHub App user token. Private and internal repository contributions require the optional `read:user` scope; repository names/details additionally depend on the viewer's repository access. Store tokens only in macOS Keychain. For a lower-friction first version, invoke `gh api graphql` when GitHub CLI is already authenticated, and store no GitHub secret in AgentActivity.

The contribution calendar follows GitHub's contribution rules rather than being an all-branch commit ledger. Commits must be attributable to an email connected to the GitHub account, be in a standalone repository, and reach the default or `gh-pages` branch; private activity may be count-only ([GitHub contribution criteria](https://docs.github.com/en/account-and-profile/reference/profile-contributions-reference)). The GitHub graph uses UTC, so label its day boundary as GitHub/UTC instead of silently rebucketing counts into the Mac's local timezone.

### Commit detail and recent activity

For hover details or repository drill-down, use `GET /repos/{owner}/{repo}/commits?author={login-or-email}&since={ISO}&until={ISO}&per_page=100`. It works unauthenticated for public data; private repositories require Contents read permission. It returns SHA, author/committer timestamps, message, verification, and repository links ([GitHub REST commits](https://docs.github.com/en/rest/commits/commits#list-commits)).

Do not use REST user events as the annual heatmap source. GitHub documents a maximum of 300 events, only the last 30 days, and latency from roughly 30 seconds to 6 hours ([GitHub REST events](https://docs.github.com/en/rest/activity/events)). It is suitable only for a recent-activity list.

## Local Git as the canonical commit ledger

Ask the user to choose repository roots; do not recursively scan the entire home directory. Store security-scoped bookmarks if the sandboxed app later needs persistent folder access. For each configured repository, run read-only Git commands using explicit argument arrays, not a shell string.

A suitable history command is conceptually:

```text
git -C <repo> log --all --since=<start> --until=<end>
  --author=<configured-name-or-email>
  --format=<NUL-delimited sha, author, dates, subject, parents>
  --numstat
```

`git log` officially supports `--since`, `--until`, `--author`, and `--committer` filters ([Git log](https://git-scm.com/docs/git-log)). Use `--all` when the user wants work on unmerged/local branches; use only the default/upstream branch when matching GitHub's contribution rules. Deduplicate by `(repository identity, full SHA)`. Keep author date and commit date separately because rebases/amends can change their relationship.

Local Git tells us **what was committed**, not **which agent authored it**. Create a separate `CommitAttribution` record:

| Confidence | Allowed evidence |
| --- | --- |
| `verified` | Provider explicitly returned the SHA/conversation attribution, e.g. Cursor AI Code Tracking. |
| `linked` | Provider explicitly returned a branch/repository and the commit belongs uniquely to that agent-owned branch during the run. |
| `derived` | Same repository, nearby timestamps, and substantial overlap between provider-recorded edited paths and commit paths. Store reasons and score. |
| `unknown` | No defensible relationship; show under GitHub/Git rather than a provider. |

Never infer provider from the commit author's name, a generic branch prefix alone, or the fact that an agent session happened on the same day.

## Normalized data model

Keep immutable raw-source records for debugging and a normalized event layer for UI aggregation.

```swift
enum Provider: String { case cursor, codex, claude, github, other }
enum ExecutionLocation: String { case local, cloud, ide, cli, web, unknown }
enum ActivityKind: String {
    case session, run, turn, subagent, toolCall, fileEdit
    case commit, pullRequest, issue, review, contribution
}

struct ActivityEvent {
    let id: String                 // provider + source-stable ID
    let provider: Provider
    let executionLocation: ExecutionLocation
    let kind: ActivityKind
    let occurredAt: Date
    let endedAt: Date?
    let rootActivityID: String?    // conversation/thread/agent
    let childActivityID: String?   // turn/run/subagent/tool call
    let repositoryID: String?      // normalized remote or privacy-preserving local ID
    let branch: String?
    let commitSHA: String?
    let model: String?
    let status: String?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let linesAdded: Int?
    let linesDeleted: Int?
    let toolCalls: Int?
    let sourceName: String
    let sourceRecordID: String
    let sourceSemantics: String    // local time, UTC daily bucket, GitHub UTC, etc.
}
```

Add separate `Repository`, `Commit`, and `CommitAttribution` tables. A GitHub contribution and a provider event can both point at one `Commit` without duplicating it.

### Daily aggregation rules

- **Things worked on:** distinct `rootActivityID` with activity on that day. A session active on two days counts once on each active day, not only on its start day.
- **Agents:** distinct root agents plus subagent IDs; show root/subagent breakdown.
- **Commits:** distinct canonical repository + full SHA. Provider-reported aggregate commit counts without SHAs remain aggregate metrics and must not be merged into SHA rows.
- **Tokens:** retain categories; “total” should be an explicit formula. Do not add cached input twice when a provider already supplies a total.
- **Lines:** prefer provider-attributed lines in provider tabs and Git numstat in GitHub/Git views; label the measurement.
- **GitHub contributions:** use GitHub's returned daily `contributionCount`; hover can break out commits/PRs/issues/reviews when the API provides sufficient detail.
- **Missing data:** display `—` or “Not available for this account/source,” never zero.

All normalized rows need provenance and a uniqueness key. This prevents double-counting when, for example, a Cursor cloud run appears in both `/v1/agents/{id}/usage` and the team usage-events feed, or a Claude session appears in hooks and OTel.

## Ingestion and privacy design

1. Store data in `~/Library/Application Support/AgentActivity/` with a SQLite store and a small append-only inbox for hook records.
2. Store Cursor/GitHub/Anthropic credentials only in macOS Keychain. Reuse provider CLI authentication where practical; never scrape `auth.json`, cookies, or browser storage.
3. Make every integration opt-in. Explain what will be read and whether data leaves the Mac.
4. Default to metadata only: IDs, timestamps, provider, model, status, counts, repository identifier, branch, and SHA. Do not retain prompts, model responses, thought text, file contents, diffs, or terminal output.
5. Derive counts from sensitive payloads in memory and discard the payload. Repository paths may be hashed or redacted in privacy mode.
6. Respect provider retention/history-disable settings. A missing transcript is not an error and must not be worked around.
7. Keep daily bucket semantics. Claude organization analytics and GitHub contributions are UTC; Codex/other provider buckets may be provider-defined. Event-level timestamps can be rebucketed to the Mac timezone, but aggregate-only UTC data cannot be accurately shifted after the fact.
8. Cache aggressively and use incremental cursors. Cursor explicitly recommends no more than hourly Admin usage polling; GitHub REST events are delayed and should not drive real-time UI.

## Recommended implementation order

1. **GitHub tab:** GraphQL contribution calendar and optional REST commit drill-down. It is the cleanest complete annual heatmap.
2. **Codex personal/local:** App Server `thread/list`/`thread/read`, `account/usage/read`, plus `codex cloud list --json`. Add live events after the initial importer.
3. **Claude personal/local:** opt-in hooks plus OTel/status-line inbox. Add the organization daily Analytics API only when an admin key is configured.
4. **Cursor cloud:** Cloud Agents list/runs/usage with a user API key.
5. **Cursor local:** hooks for new activity. Add Admin usage and AI Code Tracking for eligible team/Enterprise accounts.
6. **Local Git correlation:** selected repositories, canonical commits, then confidence-labelled attribution.

This sequence produces truthful data early. It also lets the UI show capability badges such as “exact tokens,” “aggregate only,” “derived commit match,” or “history unavailable,” instead of presenting every provider as if it exposed the same telemetry.
