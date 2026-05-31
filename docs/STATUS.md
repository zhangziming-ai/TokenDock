# Status

## 2026-05-31

- Created local project workspace on the Desktop:
  - `/Users/zhangziming/Desktop/TokenDock`
- Chosen app and future repository name:
  - `TokenDock`
- Target:
  - Native macOS menu bar app.
- Current Codex quota check:
  - Plan: Plus
  - 5h window: 87% used, 13% left
  - 5h reset: 2026-05-31 20:21:26 +08:00
  - 7d window: 14% used, 86% left
  - 7d reset: 2026-06-07 15:21:26 +08:00
- Implemented native Swift/AppKit menu bar app.
- Built and installed local app:
  - `/Applications/TokenDock.app`
- Verified running process:
  - `/Applications/TokenDock.app/Contents/MacOS/TokenDock`
- Verified snapshot command:
  - `TokenDock --snapshot`
- Latest verified menu title:
  - `Codex 5h 2% · 7d 16%`
- Verified fallback behavior:
  - Empty sessions root shows `Codex --`
  - Malformed JSONL does not crash the parser
- Updated menu UI:
  - Colored section headers for official quota, latest event, local totals, and source.
  - Time windows and token values are shown as clear label/value rows.
  - The dropdown is easier to scan than the original plain text menu.
- Added API usage placeholder:
  - Orange `API Tokens` section between official quota and latest event.
  - Shows `Today`, `Last 5h`, and `Last 7d` as `--` until an API usage source is connected.
- Updated official quota display:
  - 5h and 7d rows now show used/left percentages with horizontal progress bars.
  - Reset time remains visible under each progress bar.

## Notes

MioIsland/CodeIsland were not reliable enough for the desired usage view because they surface rate-limit percentages rather than a clear local token summary.
