# AgentActivity Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish AgentActivity as a polished private GitHub repository with portable Cursor and Claude hooks, an original macOS squircle icon, universal signed/notarized release tooling, CI, and complete operator documentation.

**Architecture:** Keep the SwiftPM menu-bar application intact, add a dependency-free `AgentActivityHook` executable backed by a testable core target, and assemble both binaries into a conventional universal macOS app bundle. Adapt Zonely's local-first Developer ID release pipeline and manual GitHub Actions fallback while preserving AgentActivity's metadata-only privacy model.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Foundation, XCTest, Bash 3.2-compatible shell scripts, Swift Package Manager, `codesign`, `notarytool`, `stapler`, `hdiutil`, GitHub CLI, and GitHub Actions.

> **Implementation status (2026-08-08):** The dated implementation note at the end of this plan supersedes the GitHub artifact-attestation and private-vulnerability-reporting steps below while retaining the approved plan history.

## Global Constraints

- Keep AgentActivity native, menu-bar-only, and compatible with macOS 13 or later.
- Preserve `NSStatusItem`, the pre-sized non-animated `NSPopover`, and `LSUIElement=true`.
- Add no third-party runtime dependency and no analytics, account, or network service beyond the existing explicit GitHub/Codex integrations.
- Never store prompts, responses, transcript contents, commands, tool inputs/results, source code, environment variables, or credentials.
- Cursor roots come from `conversation_id` and `workspace_roots`; Claude roots come from `session_id`, `cwd`, and `CwdChanged`.
- Treat Git/agent attribution as derived, not definitive proof of authorship.
- The GitHub repository is `adithyaakrishna/agent-activity`, private, with default branch `main` and no open-source license.
- The primary release path is a Developer ID-signed and Apple-notarized private GitHub Release; App Store distribution is excluded.
- Commit generated app-icon assets, but never commit `.env`, signing certificates, passwords, hook logs, local activity data, or build products.

---

## File ownership map

- `Sources/AgentActivityHookCore/`: JSON minimization, Git metadata, bounded append-only storage, and user-config mutation.
- `Sources/AgentActivityHook/`: thin command-line entry point only.
- `Tests/AgentActivityHookCoreTests/`: capture privacy and configuration install/uninstall behavior.
- `script/lib/`: shared version, environment, signing, checksum, and notarization functions.
- `script/*.sh`: build, package, verify, credential setup, and release orchestration.
- `Assets/` and `Resources/Info.plist`: app icon source, generated `.icns`, and bundle metadata.
- `.github/`: CI, manual release fallback, release notes, Release Drafter, and Dependabot.
- `README.md` and `SECURITY.md`: product, privacy, development, release, and reporting documentation.

Workers must not edit files outside their assigned task unless the primary agent explicitly reassigns ownership.

---

### Task 1: Privacy-minimized compiled hook capture

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentActivityHookCore/HookProvider.swift`
- Create: `Sources/AgentActivityHookCore/HookCaptureProcessor.swift`
- Create: `Sources/AgentActivityHookCore/GitHeadInspector.swift`
- Create: `Sources/AgentActivityHookCore/HookRecordStore.swift`
- Create: `Sources/AgentActivityHook/AgentActivityHookMain.swift`
- Create: `Tests/AgentActivityHookCoreTests/HookCaptureProcessorTests.swift`
- Create: `Tests/AgentActivityHookCoreTests/HookRecordStoreTests.swift`

**Interfaces:**
- Produces: `enum HookProvider: String { case cursor, claude }`.
- Produces: `struct HookCaptureProcessor` with `func makeRecord(input: Data, provider: HookProvider, capturedAt: Date, environment: [String: String]) throws -> [String: Any]?`.
- Produces: `protocol GitHeadInspecting` and `struct GitHeadMetadata` with SHA, commit date, additions, and deletions.
- Produces: `struct HookRecordStore` with `func append(_ record: [String: Any], provider: HookProvider, directory: URL) throws`.
- Consumes later: the executable accepts `capture cursor` or `capture claude`, reads one JSON object from standard input, and returns exit code zero even when capture fails.

- [ ] **Step 1: Add failing privacy and provider tests**

Create tests with payloads that deliberately include `prompt`, `response`, `command`, `tool_input`, `tool_response`, and transcript text. Assert that Cursor maps `conversation_id` and the first `workspace_roots` entry; Claude maps `session_id` and `cwd`; and the serialized record contains none of the forbidden keys or sentinel values.

```swift
func testCursorPayloadKeepsMetadataAndDropsContent() throws {
    let input = Data(#"{"conversation_id":"c-1","workspace_roots":["/tmp/repo"],"hook_event_name":"stop","prompt":"DO_NOT_STORE","tool_input":{"command":"DO_NOT_STORE"}}"#.utf8)
    let record = try HookCaptureProcessor(git: StubGitHeadInspector()).makeRecord(
        input: input,
        provider: .cursor,
        capturedAt: Date(timeIntervalSince1970: 0),
        environment: [:]
    )
    XCTAssertEqual(record?["session_id"] as? String, "c-1")
    XCTAssertEqual(record?["repository_root"] as? String, "/tmp/repo")
    let encoded = try JSONSerialization.data(withJSONObject: XCTUnwrap(record))
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(text.contains("DO_NOT_STORE"))
    XCTAssertNil(record?["prompt"])
    XCTAssertNil(record?["tool_input"])
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run: `swift test --filter AgentActivityHookCoreTests.HookCaptureProcessorTests`

Expected: build failure because `AgentActivityHookCore`, `HookCaptureProcessor`, and the test target do not exist.

- [ ] **Step 3: Add the SwiftPM targets and minimal capture implementation**

Add `AgentActivityHookCore` as a regular target, `AgentActivityHook` as an executable target depending on it, and `AgentActivityHookCoreTests` as a test target. Decode JSON with `JSONSerialization`, construct a new allow-listed dictionary, and never mutate or re-encode the original payload.

Claude capture must return `nil` unless `transcript_path` contains `/.claude/projects/`. Resolve a candidate directory through `/usr/bin/git -C <path> rev-parse --show-toplevel`. Only attach Git HEAD data for `stop`, `sessionEnd`, `SessionEnd`, or `afterFileEdit`, and only accept a 40-character hexadecimal SHA.

- [ ] **Step 4: Add failing bounded-store tests**

Test that the store creates mode-`0600` JSONL, appends one compact line, rotates `cursor.jsonl` to `cursor.jsonl.1` after a configurable 25 MB limit, and never creates more than one backup.

```swift
func testStoreWritesOwnerOnlyJSONLine() throws {
    let directory = temporaryDirectory()
    try HookRecordStore(maxBytes: 1024).append(
        ["provider": "cursor", "session_id": "c-1"],
        provider: .cursor,
        directory: directory
    )
    let file = directory.appendingPathComponent("cursor.jsonl")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(try String(contentsOf: file).split(separator: "\n").count, 1)
}
```

- [ ] **Step 5: Implement atomic append, locking, and rotation**

Use Darwin `open` with `O_APPEND | O_CREAT`, mode `0600`, and `flock(LOCK_EX)` around size inspection, rotation, and write. Serialize with `.sortedKeys`, append exactly one newline, cap the default at `26_214_400` bytes, and use `cursor.jsonl.1`/`claude.jsonl.1` as the only backups.

- [ ] **Step 6: Add the fail-open executable entry point**

`AgentActivityHookMain` must parse only `capture <provider>` for this task, read standard input once, write no stdout/stderr on ordinary capture failures, use `~/Library/Application Support/AgentActivity/hooks`, and exit zero so telemetry cannot block provider work.

- [ ] **Step 7: Run capture tests and the full suite**

Run: `swift test --filter AgentActivityHookCoreTests && swift test`

Expected: all hook-core and existing AgentActivity tests pass.

- [ ] **Step 8: Commit the capture helper**

```bash
git add Package.swift Sources/AgentActivityHookCore Sources/AgentActivityHook Tests/AgentActivityHookCoreTests
git commit -m "Add portable agent activity hook capture"
```

---

### Task 2: Safe hook installation and surgical uninstall

**Files:**
- Create: `Sources/AgentActivityHookCore/HookConfigurationManager.swift`
- Modify: `Sources/AgentActivityHook/AgentActivityHookMain.swift`
- Create: `Tests/AgentActivityHookCoreTests/HookConfigurationManagerTests.swift`
- Modify: `script/agent_activity_hook.sh`

**Interfaces:**
- Produces: `struct HookConfigurationManager` with `install(helperSource: URL, homeDirectory: URL, timestamp: Date) throws` and `uninstall(homeDirectory: URL, timestamp: Date) throws`.
- Produces: stable installed helper path `~/Library/Application Support/AgentActivity/bin/AgentActivityHook`.
- Consumes: `HookProvider` and the executable's `capture` subcommand from Task 1.
- Produces later: executable commands `AgentActivityHook install` and `AgentActivityHook uninstall`.

- [ ] **Step 1: Write failing configuration-preservation tests**

Build temporary home-directory fixtures containing unrelated Cursor and Claude hooks, plugin settings, and theme values. Assert installation preserves them, adds each AgentActivity command exactly once, creates a timestamped backup beside every changed existing file, copies the helper with mode `0755`, and remains idempotent on a second run.

```swift
func testInstallPreservesUnrelatedClaudeSettingsAndIsIdempotent() throws {
    let home = try fixtureHome(claudeSettings: [
        "theme": "dark",
        "hooks": ["Stop": [["hooks": [["type": "command", "command": "existing-tool"]]]]],
    ])
    let manager = HookConfigurationManager()
    try manager.install(helperSource: fixtureHelper(), homeDirectory: home, timestamp: fixedDate)
    try manager.install(helperSource: fixtureHelper(), homeDirectory: home, timestamp: fixedDate)
    let settings = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
    XCTAssertEqual(settings["theme"] as? String, "dark")
    XCTAssertEqual(agentActivityCommandCount(in: settings), 9)
    XCTAssertEqual(commandCount(named: "existing-tool", in: settings), 1)
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run: `swift test --filter HookConfigurationManagerTests`

Expected: build failure because `HookConfigurationManager` does not exist.

- [ ] **Step 3: Implement parse-modify-validate-atomic-write behavior**

Use `JSONSerialization` and reject any existing root that is not a JSON object. Before changing an existing config, copy it to `<name>.agentactivity-backup-YYYYMMDD-HHmmss`. Write the new JSON to a sibling temporary file, reparse it, then replace the original atomically.

Cursor config must be version `1` and register `sessionStart`, `beforeSubmitPrompt`, `afterFileEdit`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `stop`, and `sessionEnd`. Claude config must register `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `SubagentStart`, `SubagentStop`, `Stop`, `SessionEnd`, and `CwdChanged`, each as a command hook with timeout `5`.

- [ ] **Step 4: Write failing surgical-uninstall and malformed-config tests**

Assert uninstall removes only exact commands targeting the stable installed helper, retains unrelated commands in the same event arrays, prunes only newly empty AgentActivity-created containers, and leaves other settings untouched. Assert malformed JSON fails before copying the helper or rewriting either config.

- [ ] **Step 5: Implement uninstall and legacy migration**

Remove the stable helper commands plus AgentActivity's known legacy `agent_activity_hook.sh cursor|claude` commands. Do not match generic filenames or delete entire event arrays when unrelated hooks remain. Remove the installed helper only after both configs have been updated successfully.

- [ ] **Step 6: Wire install/uninstall commands and retain a development wrapper**

The executable must locate itself for `install`, copy itself to the stable path, and display a concise summary only for explicit install/uninstall commands. Replace `script/agent_activity_hook.sh` with a compatibility wrapper that executes the built `AgentActivityHook capture <provider>` and contains no JSON parsing or Homebrew dependency.

- [ ] **Step 7: Run installer tests and migrate this Mac's existing hooks**

Run: `swift test --filter HookConfigurationManagerTests && swift test`

After a distribution build makes the helper available, run its `install` command. Validate both user configs with `plutil -lint` or `jq empty`, then send synthetic Cursor and Claude payloads containing `DO_NOT_STORE` and confirm the inbox never contains that sentinel.

- [ ] **Step 8: Commit portable installation**

```bash
git add Sources/AgentActivityHookCore Sources/AgentActivityHook Tests/AgentActivityHookCoreTests script/agent_activity_hook.sh
git commit -m "Add safe Cursor and Claude hook installation"
```

---

### Task 3: Universal build, packaging, signing, and release scripts

**Files:**
- Create: `script/lib/common.sh`
- Create: `script/lib/signing.sh`
- Create: `script/build_app.sh`
- Modify: `script/build_and_run.sh`
- Create: `script/create_dmg.sh`
- Create: `script/build_distribution.sh`
- Create: `script/verify_distribution.sh`
- Create: `script/setup_release_credentials.sh`
- Create: `script/release.sh`
- Create: `script/release_github.sh`
- Create: `script/test_release_lib.sh`

**Interfaces:**
- Consumes: SwiftPM products `AgentActivity` and `AgentActivityHook` from Task 1.
- Consumes: `Resources/Info.plist` and `Assets/AgentActivity.icns` from Task 4.
- Produces: `build_app.sh` environment contract `CONFIGURATION`, `VERSION`, `BUILD_NUMBER`, `OUTPUT_DIR`, `SIGNING_IDENTITY`, and `UNIVERSAL`.
- Produces: release artifact names `AgentActivity-<version>-macos-universal.{dmg,zip}` and adjacent `.sha256` files.

- [ ] **Step 1: Write failing release-library fixtures**

`script/test_release_lib.sh` must source `script/lib/common.sh`, accept `0.1.0`, `1.2.3-beta.1`, and `2.0.0-rc.1`, reject `v1.0`, `1.0`, whitespace, and shell metacharacters, and verify artifact-name construction never escapes the requested output directory.

```bash
assert_valid 0.1.0
assert_valid 1.2.3-beta.1
assert_invalid v1.0
assert_invalid '1.0.0; touch /tmp/nope'
assert_equal "$(artifact_basename 1.2.3)" "AgentActivity-1.2.3-macos-universal"
```

- [ ] **Step 2: Run the shell fixture and confirm it fails**

Run: `bash script/test_release_lib.sh`

Expected: failure because `script/lib/common.sh` does not exist.

- [ ] **Step 3: Implement focused shared shell libraries**

Define `die`, `require_command`, `validate_version`, `artifact_basename`, `sha256_file`, `load_optional_env`, and `require_clean_worktree` in `common.sh`. Define `find_developer_id_identity`, `codesign_bundle`, `submit_notarization`, and `staple_artifact` in `signing.sh`. Never echo secret values.

- [ ] **Step 4: Implement universal app assembly**

For each architecture, call `swift build --configuration "$CONFIGURATION" --arch "$arch"` with a distinct scratch path. Use `lipo -create` when universal, copy the app binary to `Contents/MacOS/AgentActivity`, the helper to `Contents/Helpers/AgentActivityHook`, the icon to `Contents/Resources/AgentActivity.icns`, and the plist to `Contents/Info.plist`. Set `CFBundleShortVersionString` and `CFBundleVersion` with `/usr/libexec/PlistBuddy`.

Sign the helper before the outer app. Use ad-hoc identity `-` for local/CI builds and `codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY"` for Developer ID builds.

- [ ] **Step 5: Refactor local run modes onto `build_app.sh`**

Keep `run`, `debug`, `logs`, `telemetry`, and `verify`. Do not delete arbitrary distribution directories; replace only the resolved `dist/AgentActivity.app`. Verification must launch the bundle, wait no more than ten seconds, and confirm the exact process is alive.

- [ ] **Step 6: Implement DMG/ZIP/checksum distribution**

Create a staging directory with `AgentActivity.app` and an `Applications` symlink. Build a compressed DMG with `hdiutil create`, a metadata-preserving ZIP with `ditto -c -k --sequesterRsrc --keepParent`, and SHA-256 files using `shasum -a 256`.

When `NOTARIZE=1`, notarize the ZIP containing the app, staple the app, rebuild the final ZIP, notarize the DMG, and staple the DMG. Use a named Keychain profile by default; do not accept an Apple password on the command line.

- [ ] **Step 7: Implement distribution verification**

Use `plutil`, `lipo -verify_arch arm64 x86_64`, `codesign --verify --deep --strict`, `hdiutil attach -readonly -nobrowse`, `ditto` extraction, and checksum verification. When `REQUIRE_NOTARIZATION=1`, additionally use `codesign -d --verbose=4`, `spctl --assess --type execute`, and `xcrun stapler validate` for the app and DMG.

- [ ] **Step 8: Implement credential setup and local release orchestration**

`setup_release_credentials.sh github` checks `gh auth status`, locates a Developer ID Application identity, prompts through `xcrun notarytool store-credentials AgentActivity-Notary`, and stores only `SIGNING_IDENTITY` plus `NOTARY_PROFILE` in ignored `.env`.

`release.sh github <version> [--dry-run]` validates arguments and delegates. Real release requires clean `main`, runs lint/tests/build/verify, creates and pushes `v<version>`, and publishes DMG, ZIP, checksums, and generated notes using `gh release create`. Dry-run uses ad-hoc signing, skips notarization/tagging/pushing/publishing, but performs the full unsigned build and verification path.

- [ ] **Step 9: Run shell, test, local app, and unsigned distribution checks**

Run:

```bash
bash -n script/*.sh script/lib/*.sh
bash script/test_release_lib.sh
swift test --parallel
./script/build_and_run.sh --verify
VERSION=0.0.0-ci BUILD_NUMBER=1 ./script/build_distribution.sh
VERSION=0.0.0-ci ./script/verify_distribution.sh
./script/release.sh github 0.1.0 --dry-run
```

Expected: all commands succeed without requiring Apple credentials or publishing.

- [ ] **Step 10: Commit release engineering**

```bash
git add script
git commit -m "Add universal signed release tooling"
```

---

### Task 4: Original squircle icon and bundle resources

**Files:**
- Create: `Assets/AgentActivityAppIcon.png`
- Create: `Assets/AgentActivity.icns`
- Create: `script/generate_app_icon.sh`
- Modify: `Resources/Info.plist`
- Verify: `Sources/AgentActivity/App/MenuBarController.swift`

**Interfaces:**
- Produces: 1024 px RGBA master and `.icns` containing 16, 32, 128, 256, 512, and 1024 px representations.
- Produces: `CFBundleIconFile=AgentActivity` for Task 3's app assembly.
- Preserves: monochrome SF Symbol `square.grid.3x3.fill` for the adaptive menu-bar item.

- [ ] **Step 1: Generate the icon master with the built-in image tool**

Use this exact production prompt:

```text
Use case: logo-brand
Asset type: native macOS menu-bar application icon master
Primary request: Create an original macOS-style application icon for AgentActivity, a private utility that visualizes coding-agent activity as a calendar heatmap.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for later removal; no floor plane, texture, reflection, or lighting variation outside the icon.
Subject: one centered deep-graphite squircle with generous outer padding; inside it, a compact calendar heatmap made of a small regular grid of rounded green cells, with one brighter emerald cell as the focal point.
Style/medium: premium native macOS icon, restrained dimensional material, crisp silhouette, subtle internal top highlight, calm and precise rather than playful.
Composition/framing: square 1024 by 1024 composition; icon centered; simple geometry readable at 16 pixels; consistent padding on every side.
Color palette: graphite, charcoal, emerald, and muted green only inside the icon; do not use #ff00ff in the subject.
Constraints: original mark; no Apple logo; no text; no letters; no numbers; no mascot; no watermark; no cast shadow outside the squircle; crisp separated edges.
Avoid: photorealistic desk scenes, excessive glass distortion, tiny decoration, neon bloom, busy gradients, GitHub branding, Cursor branding, Claude branding, and copied third-party marks.
```

- [ ] **Step 2: Remove the chroma key and inspect the alpha result**

Copy the generated source into a project-local working location, then run the installed `remove_chroma_key.py` helper with border auto-keying, soft matte, thresholds `12` and `220`, and despill. Validate an alpha channel, transparent corners, no magenta fringe, a centered squircle, and legibility at 16 and 32 px. Retry once with `--edge-contract 1` only if a fringe remains.

- [ ] **Step 3: Add a deterministic iconset generator**

`generate_app_icon.sh` validates that the master is exactly 1024×1024 with alpha, uses `sips` to produce all standard and `@2x` iconset filenames, runs `iconutil -c icns`, and confirms the output with `iconutil -c iconset` into a temporary validation directory.

- [ ] **Step 4: Add bundle icon/version metadata**

Set `CFBundleIconFile` to `AgentActivity`, add `CFBundleShortVersionString` with development default `0.1.0-dev`, add `CFBundleVersion` with default `0`, and preserve `LSUIElement`, `NSHighResolutionCapable`, bundle identifier, and macOS 13 minimum.

- [ ] **Step 5: Build and visually verify app and menu-bar treatments**

Run `./script/generate_app_icon.sh` and Task 3's local build. Inspect the master and representative downscales, verify Finder shows the full-color squircle, and confirm the menu bar still uses the adaptive monochrome SF Symbol in both light and dark appearances.

- [ ] **Step 6: Commit visual resources**

```bash
git add Assets Resources/Info.plist script/generate_app_icon.sh Sources/AgentActivity/App/MenuBarController.swift
git commit -m "Add AgentActivity app icon"
```

---

### Task 5: GitHub automation, README, and security documentation

**Files:**
- Modify: `.gitignore`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `.github/workflows/release-notes.yml`
- Create: `.github/workflows/release-drafter.yml`
- Create: `.github/dependabot.yml`
- Create: `.github/release-drafter.yml`
- Create: `.github/release.yml`
- Modify: `README.md`
- Create: `SECURITY.md`

**Interfaces:**
- Consumes: Task 3 script commands and artifact names.
- Consumes: Task 4 icon path and `Snapshots/agent-activity-native.png`.
- Produces: CI on `main`, pull requests, and manual dispatch; manual signed-release fallback; categorized release notes.

- [ ] **Step 1: Expand ignore rules before automation**

Ignore `.build/`, `dist/`, `.env`, `.env.*` except documented examples, `.DS_Store`, Xcode user data, `*.p12`, `*.cer`, `*.provisionprofile`, `*.keychain-db`, `*.notary`, local hook JSONL, and local activity databases. Do not ignore `Assets/*.png`, `Assets/*.icns`, repository screenshots, docs, or workflow files.

- [ ] **Step 2: Add least-privilege CI**

Create two macOS jobs: `quality` runs `bash -n`, `bash script/test_release_lib.sh`, `swift format lint --recursive --strict Sources Tests Package.swift`, and `swift test --parallel`; `distribution` depends on quality, builds version `0.0.0-ci`, verifies the unsigned universal DMG/ZIP, and uploads four artifacts for seven days. Use concurrency cancellation for superseded CI runs and `contents: read` by default.

- [ ] **Step 3: Add the manual signed-release fallback**

Accept a required semantic `version` input. Validate the five documented GitHub secrets, import the `.p12` into a temporary Keychain, find the Developer ID Application identity, run Task 3's distribution with `NOTARIZE=1`, verify with `REQUIRE_NOTARIZATION=1`, attest DMG and ZIP provenance, publish or update the private GitHub Release, and delete the Keychain under `if: always()`.

- [ ] **Step 4: Add Release Drafter, categorized notes, and Dependabot**

Use categories `Features`, `Fixes`, `Privacy & Security`, `Accessibility`, `Performance`, `Documentation`, `Dependencies`, and `Maintenance`. Auto-label from conventional title prefixes, branch names, and file paths. Generate release notes with a Download preamble naming the universal signed/notarized DMG and checksum files. Schedule GitHub Actions dependency updates weekly.

- [ ] **Step 5: Replace the README with complete private-product documentation**

Lead with `Assets/AgentActivityAppIcon.png` at 144 px, centered name/value statement, CI and release badges, and `Snapshots/agent-activity-native.png`. Document the five source tabs; exact/derived/unavailable metrics; macOS 13 requirement; private-release installation; hook `install`/`uninstall`; Application Support storage; GitHub CLI authentication; folder permissions for historical Git correlation; development commands; architecture; test commands; dry-run and real release commands; Apple signing prerequisites; workflow secrets; troubleshooting; privacy; and security reporting.

Use direct language. Explicitly state that Cursor does not expose exact personal token totals, Claude tokens come from local transcript usage records, Codex uses App Server usage/thread methods, GitHub uses the authenticated contribution calendar, and commit association remains derived.

- [ ] **Step 6: Add the private security policy**

Direct reports to GitHub's private vulnerability-reporting flow. State that fixes apply to the latest release line and ask reporters not to place prompt, transcript, credentials, or private repository content in an issue.

- [ ] **Step 7: Validate YAML, links, scripts, formatting, and tests**

Run:

```bash
for file in .github/workflows/*.yml .github/*.yml; do ruby -e 'require "yaml"; YAML.load_file(ARGV[0], aliases: true)' "$file"; done
bash -n script/*.sh script/lib/*.sh
swift format lint --recursive --strict Sources Tests Package.swift
swift test --parallel
```

Expected: YAML parses, shell syntax passes, Swift formatting passes, and all tests pass.

- [ ] **Step 8: Commit automation and documentation**

```bash
git add .gitignore .github README.md SECURITY.md
git commit -m "Add CI and release documentation"
```

---

### Task 6: Integrate, publish the private repository, and verify remote CI

**Files:**
- Modify as needed: only files implicated by integration failures from Tasks 1–5
- Verify: all tracked source, tests, scripts, assets, docs, and GitHub configuration

**Interfaces:**
- Consumes: every earlier task.
- Produces: private repository `https://github.com/adithyaakrishna/agent-activity` with default branch `main`.

- [ ] **Step 1: Review all changes for privacy and repository hygiene**

Run `git status --short`, inspect every untracked file, search tracked candidates for `/Users/` followed by the current account name, `DO_NOT_STORE`, token-shaped values, `.jsonl`, `.p12`, passwords, and hook inbox paths. Personal absolute paths may appear only in ignored local user configs, never in tracked files.

- [ ] **Step 2: Run the complete local verification matrix**

```bash
bash -n script/*.sh script/lib/*.sh
bash script/test_release_lib.sh
swift format lint --recursive --strict Sources Tests Package.swift
swift test --parallel
./script/build_and_run.sh --verify
VERSION=0.0.0-ci BUILD_NUMBER=1 ./script/build_distribution.sh
VERSION=0.0.0-ci ./script/verify_distribution.sh
./script/release.sh github 0.1.0 --dry-run
```

Expected: every command succeeds; the app is running menu-bar-only; the unsigned universal artifacts and checksums verify; nothing is tagged or published.

- [ ] **Step 3: Install the compiled helper and validate live source imports**

Run `dist/AgentActivity.app/Contents/Helpers/AgentActivityHook install`, validate the Cursor and Claude JSON files, inject privacy fixtures, then run live integration tests with `AGENT_ACTIVITY_INTEGRATION_SOURCE=cursor` and `claude`. Relaunch AgentActivity and refresh both tabs.

- [ ] **Step 4: Make the repository history and branch publish-ready**

Review staged scope explicitly, commit all intended application files, and rename the local branch to `main`. Use command-scoped `-c commit.gpgsign=false` only if non-interactive GPG pinentry prevents the commit; do not change global Git signing settings.

```bash
git add .codex .gitignore .github Assets Docs Package.swift README.md Resources SECURITY.md Snapshots Sources Tests script
git commit -m "Build AgentActivity menu bar app"
git branch -M main
```

- [ ] **Step 5: Create and push the private GitHub repository**

Confirm `gh auth status`, ensure `adithyaakrishna/agent-activity` does not already exist, then create and push without making it public.

```bash
gh repo create adithyaakrishna/agent-activity \
  --private \
  --source=. \
  --remote=origin \
  --push \
  --description "A native macOS menu-bar heatmap for Cursor, Codex, Claude, and GitHub activity."
```

- [ ] **Step 6: Configure and verify repository metadata**

Set topics `macos`, `swift`, `swiftui`, `menu-bar`, `developer-tools`, `cursor`, `codex`, `claude`, and `github`. Confirm `isPrivate=true`, default branch `main`, Actions enabled, vulnerability reporting available, and no accidental release or public package exists.

- [ ] **Step 7: Watch initial CI and repair only in-scope failures**

Use `gh run list --repo adithyaakrishna/agent-activity` to find the initial CI run, then `gh run watch <run-id> --exit-status`. If CI fails, inspect logs, patch the narrow cause, rerun the local equivalent, commit, push, and watch the replacement run.

- [ ] **Step 8: Final remote and artifact audit**

Confirm the repository URL, privacy, branch, latest commit, passing CI, README rendering, icon rendering, ignored local secrets, and downloadable CI artifacts. Report the missing Apple credential/setup step if a real signed release cannot yet be created; do not fabricate notarization success.

---

## Final acceptance matrix

- [ ] Private GitHub repository exists at `adithyaakrishna/agent-activity` with `main` pushed.
- [ ] CI passes quality and unsigned universal distribution jobs.
- [ ] `swift test --parallel` and live Cursor/Claude integration checks pass.
- [ ] Local app launches only in the menu bar and uses the new Finder app icon.
- [ ] DMG and ZIP contain universal app/helper binaries and valid checksums.
- [ ] Dry-run release succeeds without signing credentials or publication.
- [ ] Real-release scripts require Developer ID, notarization, Gatekeeper, and stapling validation.
- [ ] Hook install is idempotent; uninstall is surgical; malformed configs are never overwritten.
- [ ] No prompt content, credential, personal absolute path, hook log, or build product is tracked.
- [ ] README, security policy, release notes, and workflow documentation match actual commands.

## Implementation note — 2026-08-08

The private personal repository cannot use the originally planned GitHub artifact-attestation and private-vulnerability-reporting features. The reviewed implementation uses signed/notarized artifacts, exact adjacent SHA-256 files, and conditional deterministic build-provenance metadata instead of GitHub artifact attestations. Vulnerability reports go to the monitored maintainer email in `SECURITY.md` instead of GitHub private vulnerability reporting. The original task wording is retained above for plan history; these approved deviations govern implementation and verification.
