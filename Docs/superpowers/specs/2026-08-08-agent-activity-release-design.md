# AgentActivity Repository and Release Design

Date: 2026-08-08
Status: Approved design, pending implementation plan

> **Implementation status (2026-08-08):** The dated implementation note at the end of this document supersedes the GitHub artifact-attestation and private-vulnerability-reporting assumptions below while preserving them as design history.

## Purpose

Turn the existing AgentActivity Swift package into a polished private GitHub repository with a repeatable macOS distribution system, an original Apple-style app icon, portable Cursor and Claude hooks, and documentation suitable for installing, developing, and releasing the app.

The release engineering should adapt the proven patterns in `adithyaakrishna/zonely` while remaining specific to AgentActivity. The primary distribution is a Developer ID-signed and Apple-notarized private GitHub Release. The Mac App Store is outside this scope.

## Product boundaries

AgentActivity remains a native SwiftUI/AppKit menu-bar-only application targeting macOS 13 or later. It continues to use `NSStatusItem`, a pre-sized `NSPopover`, and `LSUIElement`; it does not gain a Dock icon or conventional app window.

This work does not redesign the heatmap interface, add accounts or analytics, publish the source publicly, or claim that derived commit associations are definitive proof of agent authorship. A public open-source license is intentionally omitted from the private repository.

## Repository structure

The GitHub repository will be created as `adithyaakrishna/agent-activity`, marked private, and use `main` as its default branch. The initial repository will contain the complete current application plus release and maintenance infrastructure.

Planned top-level additions and changes:

- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `.github/workflows/release-notes.yml`
- `.github/workflows/release-drafter.yml`
- `.github/dependabot.yml`
- `.github/release-drafter.yml`
- `.github/release.yml`
- `Assets/AgentActivityAppIcon.png`
- `Assets/AgentActivity.icns`
- `SECURITY.md`
- Expanded `.gitignore`
- Expanded `README.md`
- Distribution scripts under `script/`
- A compiled hook-helper target and focused tests

Build products, `.env`, signing certificates, passwords, hook event logs, local activity databases, Xcode user state, and other machine-specific data must remain ignored.

## Build architecture

Swift Package Manager remains the source of truth. Release builds produce universal executables for `arm64` and `x86_64`, combine architecture slices with `lipo`, and assemble a conventional `.app` bundle.

`script/build_app.sh` will:

1. Validate version, build number, configuration, and signing inputs.
2. Build the application and hook helper for each requested architecture.
3. Create universal binaries when `UNIVERSAL=1`.
4. Assemble `AgentActivity.app`, including `Info.plist`, `.icns`, and the helper executable.
5. Apply ad-hoc or Developer ID signing from the inside out.
6. Validate the resulting bundle before returning success.

`script/build_and_run.sh` will delegate assembly to `build_app.sh` and preserve the existing run, debug, logs, telemetry, and verification modes.

The release scripts will share narrowly scoped helpers under `script/lib/` for environment loading, semantic-version validation, signing identity checks, checksum generation, and notarization. Scripts will use `set -euo pipefail`, explicit paths, actionable failures, and dry-run support where publishing is possible.

## Portable Cursor and Claude hooks

The current shell receiver depends on Homebrew `jq` and contains a repository-specific command path in the installed user configs. Distribution will replace that runtime dependency with a small Foundation-based Swift executable target named `AgentActivityHook`.

The helper will support three operations:

- `capture cursor` and `capture claude` read provider JSON from standard input and write only privacy-minimized metadata.
- `install` copies the universal helper into `~/Library/Application Support/AgentActivity/bin/` and safely merges AgentActivity entries into `~/.cursor/hooks.json` and `~/.claude/settings.json`.
- `uninstall` removes only AgentActivity-owned hook entries and the installed helper, preserving all unrelated user configuration and previously installed hooks.

The capture schema remains limited to provider/session identifiers, lifecycle event names, timestamps, provider-supplied repository roots, tool and agent labels, numeric counters, and optional Git HEAD metadata. Prompt text, responses, transcript contents, commands, tool inputs/results, environment variables, source code, and credentials are never written.

Cursor repository context comes from native `conversation_id` and `workspace_roots`. Claude context comes from native `session_id`, `cwd`, and `CwdChanged`. A Claude transcript-path guard prevents Cursor's optional Claude-settings compatibility from double-counting activity. Repository candidates are canonicalized through `git rev-parse --show-toplevel` without crawling broad user directories.

Hook inbox files remain under `~/Library/Application Support/AgentActivity/hooks/`, use owner-only permissions, and retain one bounded 25 MB rotated backup per provider.

## Distribution artifacts

`script/build_distribution.sh` will produce:

- `AgentActivity-<version>-macos-universal.dmg`
- `AgentActivity-<version>-macos-universal.dmg.sha256`
- `AgentActivity-<version>-macos-universal.zip`
- `AgentActivity-<version>-macos-universal.zip.sha256`

The DMG will present the application beside an Applications-folder shortcut. `script/create_dmg.sh` will build it deterministically and avoid adding machine-specific metadata.

Unsigned CI artifacts use ad-hoc signing. Private releases use a Developer ID Application identity, hardened runtime, Apple notarization through a named Keychain profile, and stapling. Notarization is required for a published release but not for ordinary local development.

`script/verify_distribution.sh` will validate:

- Bundle identifiers, minimum system version, and `LSUIElement`.
- Presence and executability of the main app and hook-helper binaries.
- Both universal architecture slices.
- Nested and outer code signatures.
- Hardened runtime for Developer ID builds.
- Gatekeeper acceptance and stapled notarization when required.
- DMG mounting and expected contents.
- ZIP contents and SHA-256 checksum files.

## Local release flow

`script/setup_release_credentials.sh github` will guide one-time setup. It will verify an authenticated GitHub CLI session, locate a Developer ID Application identity in the login Keychain, create or validate a named `AgentActivity-Notary` profile, and save only non-secret defaults in ignored local configuration.

`script/release.sh github <version> [--dry-run]` delegates to `script/release_github.sh`. A release will require a clean worktree and the `main` branch, then:

1. Validate the semantic version and confirm the tag does not exist.
2. Run formatting, shell syntax checks, tests, and hook privacy fixtures.
3. Build universal signed artifacts.
4. Notarize, staple, and verify the distribution.
5. Generate checksums and categorized release notes.
6. Create and push `v<version>`.
7. Create or update the private GitHub Release and upload all artifacts.

Dry-run mode performs every safe validation and build step but does not create tags, push, notarize, or publish.

## GitHub automation

CI runs on pull requests, pushes to `main`, and manual dispatch. It will lint Swift formatting, validate shell scripts, run the full test suite in parallel, build an unsigned universal distribution, verify it, and upload short-retention artifacts.

The manual `release.yml` workflow is a fallback, not the primary release route. It accepts a semantic version, imports a temporary Developer ID certificate into an ephemeral Keychain, signs and notarizes the artifacts, verifies them, generates provenance attestations, publishes the private release, and always deletes the temporary Keychain.

Release Drafter will maintain categorized draft notes and automatically label pull requests. Release-note categories include features, fixes, privacy and security, accessibility, performance, documentation, dependencies, and maintenance. Dependabot will check GitHub Actions dependencies weekly.

GitHub Actions permissions will use least privilege per job. Release secrets are documented by name and purpose but never committed.

## App icon and menu-bar symbol

The app icon will be an original 1024 px raster master with a macOS-style squircle silhouette. The composition uses a deep graphite surface, restrained material depth, and a compact green calendar grid with one brighter activity cell. It contains no text, mascot, watermark, or copied third-party mark.

The design prioritizes recognizability at small sizes: a simple silhouette, limited contrast hierarchy, generous internal padding, and no fine decoration that disappears below 32 px. The master is checked into `Assets/`, then `script/generate_app_icon.sh` uses macOS `sips` and `iconutil` to build the complete `.icns` representation at 16, 32, 128, 256, 512, and 1024 px including Retina variants.

The menu-bar item remains a separate monochrome template symbol so macOS can adapt it correctly for light mode, dark mode, high contrast, and menu-bar materials. The full-color squircle is reserved for Finder, release assets, and README presentation.

## README and project documentation

The README will lead with the app icon, product name, a concise value statement, the current native popover screenshot, and private-repository-compatible status badges. It will cover:

- Features and supported activity sources.
- macOS requirements and installation from a private release.
- Accuracy boundaries for token counts and derived Git associations.
- Privacy guarantees and local storage locations.
- Cursor and Claude hook installation and removal.
- GitHub CLI authentication and repository-folder permissions.
- Development commands and project architecture.
- Testing, signed builds, dry runs, and releases.
- Troubleshooting and security reporting.

`SECURITY.md` directs vulnerability reports to GitHub's private security-reporting flow. The existing official-source activity analysis remains linked from the README.

## Error handling and safety

All configuration mutations use parse-modify-write behavior with a same-directory temporary file and atomic replacement. Install and uninstall commands validate JSON before replacement and retain a timestamped backup when changing an existing settings file. An invalid or unfamiliar config aborts with instructions rather than overwriting it.

Release scripts resolve exact artifact paths, reject ambiguous versions, avoid destructive broad-directory operations, and never print credentials. Publishing is gated behind clean-tree, branch, authentication, signing, notarization, and artifact-verification checks.

Hook capture remains fail-open for the provider: recording failures never block a Cursor or Claude action. Failures write no prompt or tool payload to logs.

## Testing strategy

Tests will cover:

- Existing heatmap data generation and native popover dimensions.
- Hook payload minimization for Cursor and Claude.
- Claude compatibility-event rejection.
- Repository-root canonicalization and commit deduplication.
- Hook config installation, idempotent reinstallation, and surgical uninstall against fixtures containing unrelated hooks.
- Malformed config refusal and backup behavior.
- Version and artifact-name validation.

Repository checks include `swift format lint`, `swift test --parallel`, `bash -n` for shell files, universal-architecture inspection, app bundle validation, ad-hoc distribution verification, and signed/notarized verification before publication.

## Parallel implementation workstreams

After the implementation plan is approved, parallel agents will use disjoint ownership:

1. Release engineering: distribution scripts, signing/notarization, DMG/ZIP verification, and GitHub workflows.
2. Hook portability: compiled helper, config merge/uninstall behavior, privacy fixtures, and tests.
3. Visual and documentation: original app icon, iconset pipeline, plist integration, README, and security documentation.

The primary agent will own integration, resolve cross-workstream interfaces, run final tests, create the initial repository commit, create the private GitHub repository, push `main`, configure repository metadata, and verify the remote state.

## Completion criteria

The work is complete when:

- `adithyaakrishna/agent-activity` exists as a private GitHub repository with `main` pushed.
- A clean checkout can run tests and build/launch the menu-bar app.
- CI passes and produces a verified unsigned universal distribution.
- Local dry-run release succeeds without publishing.
- Signing/notarization setup reports any missing external Apple credential clearly.
- The app contains the original `.icns` icon and the menu-bar item remains adaptive.
- Cursor and Claude hooks install portably and preserve unrelated user settings.
- The README accurately documents installation, privacy, data accuracy, development, and release operations.
- No secret, personal absolute path, prompt content, hook log, or machine-specific build artifact is committed.

## Implementation note — 2026-08-08

Two GitHub features in the approved design are not available to this private repository under a personal GitHub account. The implementation therefore does not claim GitHub artifact attestations: signed/notarized release artifacts retain adjacent SHA-256 files, and the GitHub Actions fallback adds deterministic human-readable build provenance metadata. This metadata is not described as a cryptographic attestation. GitHub private vulnerability reporting is likewise replaced by the monitored maintainer email documented in `SECURITY.md`. These are approved platform-compatibility deviations; the original design text above remains as the historical decision record.
