# TokenDock Implementation Plan

## Summary

Build a GitHub-ready native macOS menu bar app named TokenDock. It should run locally first, then later be prepared for GitHub upload after validation.

## App Behavior

- Menu bar title:
  - `Codex 5h 69% · 7d 11%` when rate-limit data exists.
  - `Codex --` when no valid usage data exists.
- Menu contents:
  - Official rate limit: 5h, 7d, reset time, plan type.
  - Latest token event: input, cached input, output, reasoning, total.
  - Local aggregates: today, last 5 hours, last 7 days.
  - Source file path and last refresh time.
  - Actions: refresh, open sessions folder, quit.

## Implementation Notes

- Use Swift/AppKit with `NSStatusItem` and `NSMenu`.
- Set `LSUIElement=1` so the app does not show in Dock.
- Refresh every 60 seconds and on manual refresh.
- Read-only parse `~/.codex/sessions/**/rollout-*.jsonl`.
- Do not edit Codex settings or hooks.
- Do not call private web endpoints.

## Components

- `CodexUsageParser` scans rollout JSONL and creates a snapshot.
- `UsageSnapshot` stores latest official rate limits and local token aggregates.
- `StatusBarController` renders the menu bar title and dropdown.

## Validation

- Parse the current local Codex logs successfully.
- Confirm latest rate-limit values match the newest `token_count` event.
- Confirm missing or malformed logs show `Codex --` without crashing.
- Build `dist/TokenDock.app`.
- Install locally to `/Applications/TokenDock.app`.
- Launch and verify only TokenDock remains as the usage tool.

